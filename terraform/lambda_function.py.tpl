import boto3, json, time, logging
from datetime import datetime, timezone, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION        = '${region}'
WORKGROUP     = '${workgroup}'
DATABASE      = '${database}'
SES_SENDER    = '${ses_sender}'
TOP_SERVICES  = ${top_services}
TOP_RESOURCES = ${top_resources}
QUERY_TIMEOUT = 55

def run_athena_query(query):
    athena = boto3.client('athena', region_name=REGION)
    resp = athena.start_query_execution(
        QueryString=query,
        QueryExecutionContext={'Database': DATABASE},
        WorkGroup=WORKGROUP
    )
    qid = resp['QueryExecutionId']
    deadline = time.time() + QUERY_TIMEOUT
    while time.time() < deadline:
        result = athena.get_query_execution(QueryExecutionId=qid)['QueryExecution']
        status = result['Status']['State']
        if status == 'FAILED':
            raise Exception(f"Athena query failed: {result['Status'].get('StateChangeReason','Unknown')}")
        if status == 'CANCELLED':
            raise Exception('Athena query was cancelled')
        if status == 'SUCCEEDED':
            break
        time.sleep(2)
    else:
        athena.stop_query_execution(QueryExecutionId=qid)
        raise Exception(f'Athena query timed out after {QUERY_TIMEOUT}s')
    results = athena.get_query_results(QueryExecutionId=qid)
    rows = results['ResultSet']['Rows']
    headers = [c['VarCharValue'] for c in rows[0]['Data']]
    return [dict(zip(headers, [c.get('VarCharValue','') for c in row['Data']])) for row in rows[1:]]

def get_max_date():
    rows = run_athena_query("SELECT MAX(usage_date) as max_date FROM summary_view")
    return rows[0]['max_date']

def build_cur2_date_filter(period, max_dt):
    """Date filter for cur2 which uses line_item_usage_start_date."""
    if period == 'daily':
        return f"date(line_item_usage_start_date) = date '{max_dt.strftime('%Y-%m-%d')}'"
    else:
        month_start = max_dt.replace(day=1).strftime('%Y-%m-%d')
        return f"date(line_item_usage_start_date) >= date '{month_start}' AND date(line_item_usage_start_date) <= date '{max_dt.strftime('%Y-%m-%d')}'"

def get_thresholds():
    """Returns list of (tag_key, tag_value, config) tuples from all SSM params under /cost/thresholds/"""
    ssm = boto3.client('ssm', region_name=REGION)
    paginator = ssm.get_paginator('get_parameters_by_path')
    result = []
    for page in paginator.paginate(Path='/cost/thresholds', Recursive=True):
        for p in page['Parameters']:
            parts = p['Name'].strip('/').split('/')
            if len(parts) != 4:
                logger.warning('Unexpected SSM path format: %s, skipping', p['Name'])
                continue
            _, _, tag_key, tag_value = parts
            try:
                result.append((tag_key, tag_value, json.loads(p['Value'])))
            except json.JSONDecodeError:
                logger.warning('Skipping malformed SSM param: %s', p['Name'])
    return result

def send_email(recipients, subject, body):
    ses = boto3.client('sesv2', region_name=REGION)
    for recipient in recipients:
        ses.send_email(
            FromEmailAddress=SES_SENDER,
            Destination={'ToAddresses': [recipient]},
            Content={'Simple': {
                'Subject': {'Data': subject},
                'Body': {'Text': {'Data': body}}
            }}
        )

def check_period(tag_key, tag_value, period, config, max_dt):
    threshold = config.get('threshold')
    recipients = config.get('recipients', [])
    if threshold is None or not recipients:
        return False

    if period == 'daily':
        date_filter = f"usage_date = TIMESTAMP '{max_dt.strftime('%Y-%m-%d %H:%M:%S')}'"
    else:
        month_start = max_dt.replace(day=1, hour=0, minute=0, second=0).strftime('%Y-%m-%d %H:%M:%S')
        date_filter = f"usage_date >= TIMESTAMP '{month_start}' AND usage_date <= TIMESTAMP '{max_dt.strftime('%Y-%m-%d %H:%M:%S')}'"

    try:
        rows = run_athena_query(f"""
            SELECT service, region, linked_account_id as account,
                   ROUND(SUM(unblended_cost), 2) as cost
            FROM summary_view
            WHERE {date_filter}
              AND json_extract_scalar(tags_json, '$.{tag_key}') = '{tag_value}'
            GROUP BY service, region, linked_account_id
            ORDER BY cost DESC
            LIMIT {TOP_SERVICES}
        """)
    except Exception as e:
        logger.error('CUR query failed for %s=%s period=%s: %s', tag_key, tag_value, period, str(e))
        send_email(recipients,
            f'Cost Monitor ERROR: query failed for {tag_key}={tag_value} [{period}]',
            f'Athena query failed for {tag_key}={tag_value} (period={period}).\nError: {str(e)}')
        return False

    if not rows:
        logger.warning('No CUR data for %s=%s period=%s', tag_key, tag_value, period)
        send_email(recipients,
            f'Cost Monitor WARNING: no data for {tag_key}={tag_value} [{period}]',
            f'No cost data found for {tag_key}={tag_value} (period={period}).\nCheck resource tagging.')
        return False

    total = sum(float(r['cost']) for r in rows)

    if total > threshold:
        service_lines = '\n'.join(
            f"  {r['service']}: {r['region']}: {r['account']}: $${r['cost']}"
            for r in rows if float(r['cost']) > 0
        )
        try:
            cur2_tag_col = f"resource_tags_user_{tag_key.replace('tag_', '')}"
            cur2_date_filter = build_cur2_date_filter(period, max_dt)
            resources = run_athena_query(f"""
                SELECT line_item_resource_id as resource_id,
                       line_item_product_code as service,
                       product_region as region,
                       line_item_usage_account_id as account,
                       ROUND(SUM(line_item_unblended_cost), 2) as cost
                FROM cur2
                WHERE {cur2_date_filter}
                  AND {cur2_tag_col} = '{tag_value}'
                  AND line_item_resource_id != ''
                GROUP BY line_item_resource_id, line_item_product_code, product_region, line_item_usage_account_id
                ORDER BY cost DESC
                LIMIT {TOP_RESOURCES}
            """)
        except Exception as e:
            logger.error('Resource query failed: %s', str(e))
            resources = []

        resource_lines = '\n'.join(
            f"  {r['resource_id']} ({r['service']}, {r['region']}, {r['account']}): $${r['cost']}"
            for r in resources
        ) if resources else '  No resource-level data available'

        send_email(
            recipients,
            f'Cost Alert [{period}]: {tag_key}={tag_value} exceeded $${threshold}',
            f"Period: {period}\n"
            f"{tag_key}={tag_value} exceeded threshold $${threshold:.2f}\n"
            f"Total: $${total:.2f}\n\n"
            f"Top {TOP_SERVICES} services:\n{service_lines}\n\n"
            f"Top {TOP_RESOURCES} most expensive resources:\n{resource_lines}"
        )
        logger.info('Alert sent for %s=%s period=%s', tag_key, tag_value, period)
        return True

    logger.info('No breach for %s=%s period=%s', tag_key, tag_value, period)
    return False

def handler(event, context):
    alerts_sent = 0

    try:
        thresholds = get_thresholds()
    except Exception as e:
        logger.error('Failed to load thresholds from SSM: %s', str(e))
        raise

    if not thresholds:
        logger.info('No thresholds configured in SSM')
        return {'alerts_sent': 0}

    try:
        max_date = get_max_date()
        max_dt = datetime.strptime(max_date[:19], '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)
        logger.info('Max usage_date in CUR: %s', max_date)
    except Exception as e:
        logger.error('Failed to fetch max usage_date: %s', str(e))
        raise

    for tag_key, tag_value, config in thresholds:
        for period in ('daily', 'monthly'):
            period_config = config.get(period)
            if period_config is None:
                continue
            if check_period(tag_key, tag_value, period, period_config, max_dt):
                alerts_sent += 1

    logger.info('%d alert(s) sent', alerts_sent)
    return {'alerts_sent': alerts_sent}
