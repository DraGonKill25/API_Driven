# ☁️ API-Driven AWS Infrastructure Manager

This project provides a fully automated **DevOps pipeline** to deploy and manage a mock AWS infrastructure using **LocalStack**. It features a serverless architecture where an **API Gateway** triggers a **Lambda function** to control **EC2 instances** via both REST POST requests and browser-based GET requests.



---

## 🛠️ Tools & Technologies
* **LocalStack**: Local cloud stack to simulate AWS services (EC2, Lambda, API Gateway).
* **AWS CLI / awslocal**: Command-line interface for interacting with the local cloud environment.
* **Python 3.9**: Runtime for the Lambda function logic.
* **Bash**: Automation engine for the deployment pipeline.
* **GitHub Codespaces**: Development environment with dynamic port forwarding.

---

## 🚀 Getting Started

### Prerequisites
The script is designed to be **self-healing**. It will automatically check for and install the required tools (``AWS CLI``, ``LocalStack``, and ``awslocal``) if they are missing.

### Installation & Deployment
To deploy the entire infrastructure from scratch:
```bash
chmod +x automate.sh
./automate.sh
```

## 🕹️ CLI Usage Reference

The `automate.sh` script acts as a powerful management CLI.

| Command | Purpose |
| :--- | :--- |
| `./automate.sh` | **Full Setup**: Installs tools, starts LocalStack, and deploys all AWS resources. |
| `./automate.sh install` | Only installs system dependencies and Python packages. |
| `./automate.sh start` | Sends a CLI signal to start the existing EC2 instance. |
| `./automate.sh stop` | Sends a CLI signal to stop the existing EC2 instance. |
| `./automate.sh status` | Queries the local AWS provider for the **real-time** state of the instance. |
| `./automate.sh check-deploy`| Validates that the Lambda and API Gateway are correctly registered. |
| `./automate.sh help` | Displays the help menu. |

---

## 🌐 Web & API Interaction

Once deployed, the script provides a **Dynamic URL**. You can manage your instance directly from your browser using the parameters generated at the end of the deployment:

* **Check Status**: `.../manage?action=status&instance_id=i-xxx`
* **Start Instance**: `.../manage?action=start&instance_id=i-xxx`
* **Stop Instance**: `.../manage?action=stop&instance_id=i-xxx`

---

## 🔒 Security & Architecture Aspects

### 1. Identity & Access Management (IAM)
The Lambda function executes using a dedicated execution role (`manager-role`). In a production environment, this role would follow the **Principle of Least Privilege**, granting only `ec2:StartInstances`, `ec2:StopInstances`, and `ec2:DescribeInstances` permissions.

### 2. Environment Isolation
The use of **LocalStack** ensures that no real AWS costs are incurred during development. It creates a "sandbox" that mimics the production VPC (Virtual Private Cloud) environment.

### 3. Proxy Integration
The API Gateway uses **AWS_PROXY** integration. This ensures that the entire HTTP request is passed to the Lambda, allowing for robust header, method, and query parameter validation before any AWS action is taken.

### 4. Port Visibility
The script automatically configures GitHub Codespace port visibility to `public` for port `4566`, enabling the Lambda function to communicate back to the LocalStack endpoint via the dynamic proxy URL.

---

## 📂 Project Structure
* `automate.sh`: The main automation and management entry point.
* `lambda_function.py`: Python logic for the AWS Instance Manager (generated automatically).
* `deploy.log`: Detailed logs of every deployment and command execution.
* `function.zip`: Packaged Lambda deployment artifact.