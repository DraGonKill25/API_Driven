#!/bin/bash

# --- CONFIGURATION ---
LOG_FILE="deploy_docker.log"
PUBLIC_ENDPOINT="https://${CODESPACE_NAME}-4566.app.github.dev"
CONTAINER_NAME="app-container-01"

# Credentials fictifs pour AWS CLI
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

AWS_CMD="aws --endpoint-url=${PUBLIC_ENDPOINT}"

log_message() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo -e "$1"
}

# --- FONCTIONS ---

install_tools() {
    log_message "Phase 0: Checking tools..."
    if ! command -v aws &> /dev/null; then
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip && sudo ./aws/install --update
        rm -rf awscliv2.zip aws/
    fi
    [[ ! -x $(command -v localstack) ]] && pip install localstack awscli-local boto3 -q
    log_message "Tools verified."
}

start_localstack() {
    log_message "Phase 1: Starting LocalStack (Internal Docker Mode)..."
    # On autorise LocalStack à gérer ses propres conteneurs
    export LOCALSTACK_LAMBDA_DOCKER_FLAGS="-v /var/run/docker.sock:/var/run/docker.sock"
    
    localstack stop &> /dev/null
    localstack start -d >> "$LOG_FILE" 2>&1
    
    log_message "Waiting for Public Endpoint..."
    sleep 15
    
    gh codespace ports visibility 4566:public -c "$CODESPACE_NAME" &> /dev/null
}

deploy_infra() {
    log_message "Phase 2: Deploying Infrastructure..."

    # 1. On demande à LocalStack de créer et lancer le conteneur Nginx en interne
    log_message "LocalStack is pulling and starting Nginx..."
    curl -s -X POST "${PUBLIC_ENDPOINT}/v1.41/containers/create?name=${CONTAINER_NAME}" \
         -H "Content-Type: application/json" \
         -d '{"Image": "nginx:alpine"}' > /dev/null
    
    curl -s -X POST "${PUBLIC_ENDPOINT}/v1.41/containers/${CONTAINER_NAME}/start" > /dev/null

    # 2. Création de la Lambda (Pilote interne)
    cat <<EOF > lambda_function_docker.py
import json, http.client

def do_docker_req(method, path, body=None):
    conn = http.client.HTTPConnection("localhost.localstack.cloud", 4566)
    conn.request(method, path, body=body)
    resp = conn.getresponse()
    data = resp.read().decode()
    conn.close()
    return resp.status, data

def lambda_handler(event, context):
    params = event.get('queryStringParameters') or {}
    action = params.get('action', 'status')
    cont_id = params.get('container_id')

    try:
        # 1. Tenter l'action demandée
        status, data = do_docker_req("GET" if action == 'status' else "POST", 
                                     f"/v1.41/containers/{cont_id}/json" if action == 'status' else f"/v1.41/containers/{cont_id}/{action}")

        # 2. Si le conteneur n'existe pas (404), on le crée et on le lance
        if status == 404:
            do_docker_req("POST", f"/v1.41/containers/create?name={cont_id}", body=json.dumps({"Image": "nginx:alpine"}))
            do_docker_req("POST", f"/v1.41/containers/{cont_id}/start")
            return {
                'statusCode': 200,
                'body': json.dumps({'status': 'fixing', 'message': 'Infrastructure was missing. Re-created. Please refresh now.'})
            }

        # 3. Formater le résultat
        if action == 'status':
            info = json.loads(data)
            msg = f"CONTAINER STATUS: {info['State']['Status'].upper()}"
        else:
            msg = f"ACTION {action.upper()} EXECUTED"

        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'status': 'success', 'message': msg})
        }
    except Exception as e:
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
EOF

    zip -q function_docker.zip lambda_function_docker.py
    
    $AWS_CMD lambda delete-function --function-name ContainerManager 2>/dev/null
    $AWS_CMD lambda create-function --function-name ContainerManager --runtime python3.9 \
        --zip-file fileb://function_docker.zip --handler lambda_function_docker.lambda_handler \
        --role arn:aws:iam::000000000000:role/manager-role > /dev/null

    # 3. API Gateway
    log_message "Creating API Gateway..."
    API_ID=$($AWS_CMD apigateway create-rest-api --name 'DockerAPI' --query 'id' --output text)
    ROOT_ID=$($AWS_CMD apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)
    RES_ID=$($AWS_CMD apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" --path-part container --query 'id' --output text)

    for METHOD in POST GET; do
        $AWS_CMD apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method "$METHOD" --authorization-type "NONE" > /dev/null
        $AWS_CMD apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method "$METHOD" --type AWS_PROXY \
            --integration-http-method POST --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:ContainerManager/invocations > /dev/null
    done
    
    $AWS_CMD apigateway create-deployment --rest-api-id "$API_ID" --stage-name prod > /dev/null
    
    FINAL_URL="${PUBLIC_ENDPOINT}/restapis/${API_ID}/prod/_user_request_/container"
    
    log_message "Deployment Complete!"
    echo -e "\nGESTION DU CONTENEUR (Liens Publics) :"
    echo -e "----------------------------------------------------------------"
    echo -e "STATUT : ${FINAL_URL}?action=status&container_id=${CONTAINER_NAME}"
    echo -e "STOP   : ${FINAL_URL}?action=stop&container_id=${CONTAINER_NAME}"
    echo -e "START  : ${FINAL_URL}?action=start&container_id=${CONTAINER_NAME}"
    echo -e "----------------------------------------------------------------"
}

# --- LOGIQUE ---
case "$1" in
    install) install_tools ;;
    status)  $AWS_CMD lambda get-function --function-name ContainerManager ;;
    "")
        install_tools
        start_localstack
        deploy_infra
        ;;
    *)
        echo "Usage: ./automate-docker.sh [install|status]"
        exit 1
        ;;
esac