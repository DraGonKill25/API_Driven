#!/bin/bash

# --- CONFIGURATION ---
LOG_FILE="deploy.log"
DYNAMIC_URL="https://${CODESPACE_NAME}-4566.app.github.dev/"

# Redirection intelligente : tout va dans le log, et les messages importants vont à l'écran
log_message() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo -e "$1"
}

# --- FONCTIONS MODULAIRES ---

install_tools() {
    log_message "Phase 0 : Installation des outils..."
    [[ ! -x $(command -v aws) ]] && { 
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip && sudo ./aws/install --update
        rm -rf awscliv2.zip aws/
    }
    [[ ! -x $(command -v localstack) ]] && pip install localstack awscli-local boto3 -q
    log_message "Outils vérifiés/installés."
}

start_localstack() {
    log_message "Phase 1 : Démarrage LocalStack..."
    localstack start -d >> "$LOG_FILE" 2>&1
    while ! awslocal ec2 describe-instances &> /dev/null; do sleep 3; done
    log_message "LocalStack est prêt."
    sleep 5
    gh codespace ports visibility 4566:public -c "$CODESPACE_NAME" >> "$LOG_FILE" 2>&1
}

deploy_infra() {
    log_message "Phase 2 : Déploiement Infrastructure..."
    
    # 1. Récupération de l'ID Instance (On s'assure qu'il n'est pas vide)
    INSTANCE_ID=$(awslocal ec2 describe-instances --filters "Name=instance-state-name,Values=running,stopped,pending" --query "Reservations[0].Instances[0].InstanceId" --output text)
    
    if [ "$INSTANCE_ID" == "None" ] || [ -z "$INSTANCE_ID" ]; then
        log_message "Création d'une nouvelle instance..."
        awslocal ec2 run-instances --image-id ami-df23ad12 --count 1 --instance-type t2.micro > /dev/null
        sleep 2
        INSTANCE_ID=$(awslocal ec2 describe-instances --query "Reservations[0].Instances[0].InstanceId" --output text)
    fi
    log_message "Utilisation de l'instance : $INSTANCE_ID"

    # 2. Lambda (Correction de la récupération des paramètres)
    awslocal lambda delete-function --function-name InstanceManager 2>/dev/null
    cat <<EOF > lambda_function.py
import boto3, json
def lambda_handler(event, context):
    ec2 = boto3.client('ec2', endpoint_url="$DYNAMIC_URL", region_name="us-east-1")
    method = event.get('httpMethod')
    query_params = event.get('queryStringParameters') or {}
    
    # Récupération des paramètres (GET ou POST)
    if method == 'GET':
        action = query_params.get('action')
        inst_id = query_params.get('instance_id')
    else:
        body = json.loads(event.get('body', '{}'))
        action = body.get('action')
        inst_id = body.get('instance_id')

    if not action or not inst_id:
        return {'statusCode': 400, 'body': json.dumps({'error': 'Parametres manquants'})}

    try:
        if action == 'start':
            ec2.start_instances(InstanceIds=[inst_id])
            res = f"Instance {inst_id} DEMARREE"
        elif action == 'stop':
            ec2.stop_instances(InstanceIds=[inst_id])
            res = f"Instance {inst_id} ARRETEE"
        elif action == 'status':
            # VRAIE VERIFICATION DU STATUT
            status_info = ec2.describe_instances(InstanceIds=[inst_id])
            state = status_info['Reservations'][0]['Instances'][0]['State']['Name']
            res = f"L'instance {inst_id} est actuellement : {state.upper()}"
        else:
            res = "Action inconnue (utilisez start, stop ou status)"
            
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

    # 3. API Gateway (On nettoie les anciennes API pour éviter la confusion)
    log_message "Nettoyage et création API Gateway..."
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
    log_message "Déploiement terminé !"
    echo -e "\nTEST NAVIGATEUR (GET) :\n${BASE_URL}?action=stop&instance_id=${INSTANCE_ID}\n${BASE_URL}?action=start&instance_id=${INSTANCE_ID}\n${BASE_URL}?action=status&instance_id=${INSTANCE_ID}"
}

check_deploy() {
    log_message "🔍 Vérification du déploiement..."
    awslocal lambda list-functions --query "Functions[0].FunctionName"
    awslocal ec2 describe-instances --query "Reservations[*].Instances[*].[InstanceId,State.Name]" --output table
}

manage_instance() {
    local ACTION=$1
    local ID=$(awslocal ec2 describe-instances --query "Reservations[0].Instances[0].InstanceId" --output text)
    if [ "$ID" == "None" ]; then echo "Aucune instance trouvée."; return; fi
    log_message "Action $ACTION sur $ID..."
    awslocal ec2 ${ACTION}-instances --instance-ids "$ID" > /dev/null
    log_message "Instance $ID : $ACTION demandée."
}

status() {
    log_message "🔍 Vérification de l'état réel de l'instance..."
    # On récupère l'ID, l'état (running/stopped) et le nom
    awslocal ec2 describe-instances \
        --query "Reservations[*].Instances[*].[InstanceId,State.Name]" \
        --output table
}

show_help() {
    echo "Usage: ./automate.sh [COMMANDE]"
    echo ""
    echo "Commandes disponibles :"
    echo "  install      : Installe AWS CLI, LocalStack et awslocal"
    echo "  start        : Démarre l'instance EC2 existante"
    echo "  stop         : Arrête l'instance EC2 existante"
    echo "  check-deploy : Affiche l'état des ressources déployées"
    echo "  help         : Affiche cette aide"
    echo "  (vide)       : Exécute l'installation et le déploiement complet"
}

# --- LOGIQUE PRINCIPALE (CASE) ---

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
        # Par défaut : Tout faire
        install_tools
        start_localstack
        deploy_infra
        ;;
    *)
        echo "Commande inconnue : $1"
        show_help
        exit 1
        ;;
esac