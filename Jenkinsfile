pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 1, unit: 'HOURS')
        disableConcurrentBuilds()
    }

    parameters {
        choice(
            name: 'INFRA',
            choices: ['iam', 'vpc', 'rds', 'eks'],
            description: 'Select the Terraform infrastructure module'
        )

        choice(
            name: 'ENV',
            choices: ['dev', 'qa', 'uat', 'prod'],
            description: 'Select the deployment environment'
        )

        choice(
            name: 'AWS_REGION',
            choices: ['ap-south-1'],
            description: 'AWS deployment region'
        )

        booleanParam(
            name: 'IMPORT_EXISTING_IAM',
            defaultValue: true,
            description: 'One-time recovery: import existing IAM resources into Terraform state. Disable after successful import.'
        )
    }

    environment {
        AWS_DEFAULT_REGION = "${params.AWS_REGION}"

        TFLINT_VERSION = 'v0.55.0'
        TRIVY_VERSION = 'v0.71.0'
        CHECKOV_VERSION = '3.3.1'

        TF_IN_AUTOMATION = 'true'
    }

    stages {

        /*
         * STAGE 1: CHECK REQUIRED TOOLS
         */
        stage('Prerequisites') {
            steps {
                script {
                    dir("${params.INFRA}") {
                        sh '''
                            set -eu

                            echo "===== Checking Required Tools ====="

                            terraform version
                            aws --version
                            tflint --version
                            trivy --version
                            checkov --version
                            jq --version

                            echo "===== Required Tools Available ====="
                        '''
                    }
                }
            }
        }


        /*
         * STAGE 2: TERRAFORM FORMAT
         */
        stage('Format') {
            steps {
                dir("${params.INFRA}") {
                    sh '''
                        set -eu

                        echo "===== Terraform Format Check ====="

                        terraform fmt -check -recursive
                    '''
                }
            }
        }


        /*
         * STAGE 3: TFLINT
         */
        stage('Lint') {
            steps {
                dir("${params.INFRA}") {
                    sh '''
                        set -eu

                        echo "===== Initialize TFLint ====="

                        tflint --init

                        echo "===== Run TFLint ====="

                        tflint --recursive
                    '''
                }
            }
        }


        /*
         * STAGE 4: TRIVY SECURITY SCAN
         */
        stage('Trivy Security Scan') {
            steps {
                dir("${params.INFRA}") {
                    sh '''
                        set -eu

                        echo "===== Run Trivy Terraform Scan ====="

                        trivy config \
                            --severity HIGH,CRITICAL \
                            --exit-code 1 \
                            .
                    '''
                }
            }
        }


        /*
         * STAGE 5: CHECKOV SECURITY SCAN
         */
        stage('Checkov Security Scan') {
            steps {
                dir("${params.INFRA}") {
                    sh '''
                        set -eu

                        echo "===== Run Checkov ====="

                        checkov \
                            --directory . \
                            --framework terraform \
                            --quiet
                    '''
                }
            }
        }


        /*
         * STAGE 6: TERRAFORM INIT AND WORKSPACE
         */
        stage('Init') {
            steps {
                dir("${params.INFRA}") {
                    withCredentials([
                        [
                            $class: 'AmazonWebServicesCredentialsBinding',
                            credentialsId: 'awsCred'
                        ]
                    ]) {
                        sh '''
                            set -eu

                            echo "===== Verify AWS Identity ====="

                            aws sts get-caller-identity

                            echo "===== Terraform Init ====="

                            terraform init -input=false

                            echo "===== Select Terraform Workspace ====="

                            if terraform workspace select "$ENV_NAME"; then
                                echo "Existing workspace selected: $ENV_NAME"
                            else
                                echo "Workspace not found; creating: $ENV_NAME"
                                terraform workspace new "$ENV_NAME"
                            fi

                            echo "===== Current Workspace ====="

                            terraform workspace show

                            echo "===== Current Terraform State ====="

                            terraform state list || true
                        '''
                    }
                }
            }
        }


        /*
         * STAGE 7: IMPORT EXISTING IAM RESOURCES
         *
         * This stage is intended for state recovery.
         * It runs only for INFRA=iam and when the parameter is enabled.
         */
        stage('Import Existing IAM Resources') {

            when {
                allOf {
                    expression {
                        params.INFRA == 'iam'
                    }

                    expression {
                        params.IMPORT_EXISTING_IAM
                    }
                }
            }

            steps {
                dir("${params.INFRA}") {

                    withCredentials([
                        [
                            $class: 'AmazonWebServicesCredentialsBinding',
                            credentialsId: 'awsCred'
                        ]
                    ]) {

                        sh '''
                            set -euo pipefail

                            echo "===== Verify AWS Account ====="

                            aws sts get-caller-identity

                            ACCOUNT_ID=$(aws sts get-caller-identity \
                                --query Account \
                                --output text)

                            echo "AWS Account: $ACCOUNT_ID"

                            if [ "$ACCOUNT_ID" != "603033204503" ]; then
                                echo "ERROR: Unexpected AWS account."
                                exit 1
                            fi

                            echo "===== Verify Terraform Workspace ====="

                            CURRENT_WORKSPACE=$(terraform workspace show)

                            if [ "$CURRENT_WORKSPACE" != "$ENV_NAME" ]; then
                                echo "ERROR: Expected workspace $ENV_NAME"
                                echo "Current workspace: $CURRENT_WORKSPACE"
                                exit 1
                            fi

                            echo "===== Back Up Terraform State ====="

                            umask 077

                            BACKUP_FILE="$WORKSPACE/terraform-state-backup-${INFRA_NAME}-${ENV_NAME}-${BUILD_NUMBER}.json"

                            terraform state pull > "$BACKUP_FILE"

                            BACKUP_S3_URI="s3://terraform-infra-state-backend222/backups/${INFRA_NAME}/${ENV_NAME}/terraform-state-${BUILD_NUMBER}.json"

                            aws s3 cp \
                                "$BACKUP_FILE" \
                                "$BACKUP_S3_URI" \
                                --region "$AWS_DEFAULT_REGION" \
                                --sse AES256

                            echo "State backup uploaded to the configured S3 backup path."

                            /*
                             * This function skips resources already in state.
                             * Every import uses the selected environment's
                             * variable file.
                             */

                            import_if_missing() {
    ADDRESS="$1"
    RESOURCE_ID="$2"

    if terraform state show "$ADDRESS" >/dev/null 2>&1; then
        echo "Already tracked: $ADDRESS"
    else
        echo "Importing: $ADDRESS"

        terraform import -input=false "$ADDRESS" "$RESOURCE_ID"
    fi
}

                            echo "===== Import IAM Roles ====="

                            import_if_missing \
                                'module.AppDeployerRole.aws_iam_role.this[0]' \
                                'AppDeployerRole'

                            import_if_missing \
                                'module.ControlPlaneBaseRole.aws_iam_role.this[0]' \
                                'ControlPlaneBaseRole'

                            import_if_missing \
                                'module.GHActionsRole[0].aws_iam_role.this[0]' \
                                'GHActionsRole'

                            import_if_missing \
                                'module.GHAppDeployerRole.aws_iam_role.this[0]' \
                                'GHAppDeployerRole'

                            import_if_missing \
                                'module.IamProfilesRole.aws_iam_role.this[0]' \
                                'IamProfilesRole'

                            import_if_missing \
                                'module.PlatformObservabilityBaseRole.aws_iam_role.this[0]' \
                                'PlatformObservabilityBaseRole'

                            import_if_missing \
                                'module.PlatformStorageRole.aws_iam_role.this[0]' \
                                'PlatformStorageRole'

                            import_if_missing \
                                'module.PlatformVPCRole.aws_iam_role.this[0]' \
                                'PlatformVPCRole'


                            echo "===== Import IAM Policies ====="

                            import_if_missing \
                                'aws_iam_policy.AppDeployerRolePolicy' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/AppDeployerRolePolicy"

                            import_if_missing \
                                'aws_iam_policy.ControlPlaneBaseRolePolicy' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/ControlPlaneBaseRolePolicy"

                            import_if_missing \
                                'aws_iam_policy.IamProfilesRolePolicy' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/IamProfilesRolePolicy"

                            import_if_missing \
                                'aws_iam_policy.PlatformObservabilityBaseRolePolicy' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/PlatformObservabilityBaseRolePolicy"

                            import_if_missing \
                                'aws_iam_policy.PlatformStorageRolePolicy' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/PlatformStorageRolePolicy"

                            import_if_missing \
                                'aws_iam_policy.PlatformVPCRolePolicy' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/PlatformVPCRolePolicy"

                            import_if_missing \
                                'aws_iam_policy.assume_target_accounts[0]' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/assume-target-account-roles"

                            import_if_missing \
                                'aws_iam_policy.S3StateBucketPolicy' \
                                "arn:aws:iam::${ACCOUNT_ID}:policy/S3StateBucketPolicy"


                            echo "===== Find GitHub Actions OIDC Provider ====="

                            OIDC_ARN=$(aws iam list-open-id-connect-providers \
                                --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" \
                                --output text)

                            if [ -z "$OIDC_ARN" ] || [ "$OIDC_ARN" = "None" ]; then
                                echo "ERROR: GitHub Actions OIDC provider not found."
                                exit 1
                            fi

                            echo "OIDC provider found."

                            import_if_missing \
                                'module.iam_oidc_provider.aws_iam_openid_connect_provider.this[0]' \
                                "$OIDC_ARN"


                            echo "===== Final Terraform State ====="

                            terraform state list

                            echo "===== IAM Import Stage Completed ====="
                        '''
                    }
                }
            }
        }


        /*
         * STAGE 8: TERRAFORM VALIDATE
         */
        stage('Validate') {
            steps {
                dir("${params.INFRA}") {
                    sh '''
                        set -eu

                        echo "===== Terraform Validate ====="

                        terraform validate
                    '''
                }
            }
        }


        /*
         * STAGE 9: TERRAFORM PLAN
         */
        stage('Plan') {
            steps {
                dir("${params.INFRA}") {
                    withCredentials([
                        [
                            $class: 'AmazonWebServicesCredentialsBinding',
                            credentialsId: 'awsCred'
                        ]
                    ]) {
                        sh '''
                            set -eu

                            echo "===== Verify AWS Identity ====="

                            aws sts get-caller-identity

                            echo "===== Terraform Plan ====="

                            terraform plan \
                                -input=false \
                                -no-color \
                                -parallelism=50 \
                                -var-file="environments/${ENV_NAME}.auto.tfvars.json" \
                                -var="aws_region=${AWS_DEFAULT_REGION}" \
                                -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)" \
                                -var="app_env=${ENV_NAME}" \
                                -out="${INFRA_NAME}.tfplan"

                            echo "===== Plan Generated ====="
                        '''
                    }
                }
            }
        }


        /*
         * STAGE 10: MANUAL APPROVAL
         */
        stage('Approve Deploy') {
            steps {
                script {
                    def approval = input(
                        message: """
Review the Terraform plan before deployment.

Infrastructure: ${params.INFRA}
Environment: ${params.ENV}
AWS Region: ${params.AWS_REGION}

Approve only if the proposed changes are correct.
""",
                        ok: 'Approve Deployment',
                        submitterParameter: 'APPROVED_BY'
                    )

                    echo "Deployment approved by: ${approval}"
                }
            }
        }


        /*
         * STAGE 11: TERRAFORM APPLY
         */
        stage('Apply') {
            steps {
                dir("${params.INFRA}") {
                    withCredentials([
                        [
                            $class: 'AmazonWebServicesCredentialsBinding',
                            credentialsId: 'awsCred'
                        ]
                    ]) {
                        sh '''
                            set -eu

                            echo "===== Verify AWS Identity ====="

                            aws sts get-caller-identity

                            echo "===== Apply Reviewed Terraform Plan ====="

                            terraform apply \
                                -input=false \
                                -no-color \
                                -parallelism=50 \
                                "${INFRA_NAME}.tfplan"

                            echo "===== Terraform Apply Completed ====="
                        '''
                    }
                }
            }
        }
    }


    /*
     * POST ACTIONS
     */
    post {
        success {
            echo """
            =========================================
            PIPELINE COMPLETED SUCCESSFULLY
            Infrastructure: ${params.INFRA}
            Environment: ${params.ENV}
            Region: ${params.AWS_REGION}
            =========================================
            """
        }

        failure {
            echo """
            =========================================
            PIPELINE FAILED
            Infrastructure: ${params.INFRA}
            Environment: ${params.ENV}
            Check the console output for the error.
            =========================================
            """
        }

        always {
            script {
                dir("${params.INFRA}") {
                    sh '''
                        rm -f "${INFRA_NAME}.tfplan"
                    '''
                }
            }

            cleanWs()
        }
    }
}
