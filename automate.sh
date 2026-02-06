#!/bin/bash

# --- CONFIGURATION ---
LOG_FILE="deploy.log"
DYNAMIC_URL="https://${CODESPACE_NAME}-4566.app.github.dev/"

# Smart redirection: everything goes to the log, and important messages go to the screen
log_message() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo -e "$1"
}

# --- MODULAR FUNCTIONS ---

install_tools() {
    log_message "Phase 0: Installing tools..."
    [[ ! -x $(command -v aws) ]] && { 
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip && sudo ./aws/install --update
        rm -rf awscliv2.zip aws/
    }
    [[ ! -x $(command -v localstack) ]] && pip install localstack awscli-local boto3 -q
    log_message "Tools verified/installed."
}

start_localstack() {
    log_message "Phase 1: Starting LocalStack..."
    localstack start -d >> "$LOG_FILE" 2>&1
    while ! awslocal ec2 describe-instances &> /dev/null; do sleep 3; done
    log_message "LocalStack is ready."
    sleep 5
    gh codespace ports visibility 4566:public -c "$CODESPACE_NAME" >> "$LOG_FILE" 2>&1
}

deploy_infra() {
    log_message "Phase 2: Deploying Infrastructure..."
    
    # 1. Retrieve Instance ID (Ensuring it is not empty)
    INSTANCE_ID=$(awslocal ec2 describe-instances --filters "Name=instance-state-name,Values=running,stopped,pending" --query "Reservations[0].Instances[0].InstanceId" --output text)
    
    if [ "$INSTANCE_ID" == "None" ] || [ -z "$INSTANCE_ID" ]; then
        log_message "Creating a new instance..."
        awslocal ec2 run-instances --image-id ami-df23ad12 --count 1 --instance-type t2.micro > /dev/null
        sleep 2
        INSTANCE_ID=$(awslocal ec2 describe-instances --query "Reservations[0].Instances[0].InstanceId" --output text)
    fi
    log_message "Using instance: $INSTANCE_ID"

    # 2. Lambda (Parameter retrieval correction)
    awslocal lambda delete-function --function-name InstanceManager 2>/dev/null
    cat <<EOF > lambda_function.py
import boto3, json
def lambda_handler(event, context):
    ec2 = boto3.client('ec2', endpoint_url="$DYNAMIC_URL", region_name="us-east-1")
    method = event.get('httpMethod')
    query_params = event.get('queryStringParameters') or {}
    
    # Parameter retrieval (GET or POST)
    if method == 'GET':
        action = query_params.get('action')
        inst_id = query_params.get('instance_id')
    else:
        body = json.loads(event.get('body', '{}'))
        action = body.get('action')
        inst_id = body.get('instance_id')

    if not action or not inst_id:
        return {'statusCode': 400, 'body': json.dumps({'error': 'Missing parameters'})}

    try:
        if action == 'start':
            ec2.start_instances(InstanceIds=[inst_id])
            res = f"Instance {inst_id} STARTED"
        elif action == 'stop':
            ec2.stop_instances(InstanceIds=[inst_id])
            res = f"Instance {inst_id} STOPPED"
        elif action == 'status':
            # REAL STATUS CHECK
            status_info = ec2.describe_instances(InstanceIds=[inst_id])
            state = status_info['Reservations'][0]['Instances'][0]['State']['Name']
            res = f"Instance {inst_id} is currently: {state.upper()}"
        else:
            res = "Unknown action (use start, stop or status)"
            
        return {
            'statusCode': 200, 
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'status': 'success', 'message': res})
        }
    except Exception as e:
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
EOF

    zip -q function.zip lambda_function.py
    awslocal lambda create-function --function-name InstanceManager --runtime python3.9 --zip-file fileb://function.zip --handler lambda_function.lambda_handler --role arn:aws:iam::000000000000:role/manager-role > /dev/null

    # 3. API Gateway (Clean old APIs to avoid confusion)
    log_message "Cleaning up and creating API Gateway..."
    OLD_APIS=$(awslocal apigateway get-rest-apis --query "items[?name=='MyAPI'].id" --output text)
    for id in $OLD_APIS; do awslocal apigateway delete-rest-api --rest-api-id $id 2>/dev/null; done

    API_ID=$(awslocal apigateway create-rest-api --name 'MyAPI' --query 'id' --output text)
    ROOT_ID=$(awslocal apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)
    RES_ID=$(awslocal apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" --path-part manage --query 'id' --output text)

    for METHOD in POST GET; do
        awslocal apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method "$METHOD" --authorization-type "NONE" > /dev/null
        awslocal apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method "$METHOD" --type AWS_PROXY --integration-http-method POST --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:InstanceManager/invocations > /dev/null
    done
    
    awslocal apigateway create-deployment --rest-api-id "$API_ID" --stage-name prod > /dev/null
    
    BASE_URL="${DYNAMIC_URL}restapis/$API_ID/prod/_user_request_/manage"
    log_message "Deployment complete!"
    echo -e "\nBROWSER TESTS (GET):\n${BASE_URL}?action=stop&instance_id=${INSTANCE_ID}\n${BASE_URL}?action=start&instance_id=${INSTANCE_ID}\n${BASE_URL}?action=status&instance_id=${INSTANCE_ID}"
}

check_deploy() {
    log_message "Verifying deployment..."
    awslocal lambda list-functions --query "Functions[0].FunctionName"
    awslocal ec2 describe-instances --query "Reservations[*].Instances[*].[InstanceId,State.Name]" --output table
}

manage_instance() {
    local ACTION=$1
    local ID=$(awslocal ec2 describe-instances --query "Reservations[0].Instances[0].InstanceId" --output text)
    if [ "$ID" == "None" ]; then echo "No instance found."; return; fi
    log_message "Action $ACTION on $ID..."
    awslocal ec2 ${ACTION}-instances --instance-ids "$ID" > /dev/null
    log_message "Instance $ID: $ACTION requested."
}

status() {
    log_message "Checking real instance state..."
    # Retrieve ID, state (running/stopped) and name
    awslocal ec2 describe-instances \
        --query "Reservations[*].Instances[*].[InstanceId,State.Name]" \
        --output table
}

show_help() {
    echo "Usage: ./automate.sh [COMMAND]"
    echo ""
    echo "Available commands:"
    echo "  install      : Installs AWS CLI, LocalStack and awslocal"
    echo "  start        : Starts the existing EC2 instance"
    echo "  stop         : Stops the existing EC2 instance"
    echo "  check-deploy : Displays the status of deployed resources"
    echo "  status       : Displays the real state of the EC2 instance"
    echo "  help         : Displays this help message"
    echo "  (empty)      : Executes full installation and deployment"
}

# --- MAIN LOGIC (CASE) ---

case "$1" in
    install)
        install_tools
        ;;
    start)
        manage_instance "start"
        ;;
    stop)
        manage_instance "stop"
        ;;
    check-deploy)
        check_deploy
        ;;
    status)
        status
        ;;
    help)
        show_help
        ;;
    "")
        # Default: Do everything
        install_tools
        start_localstack
        deploy_infra
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac