#!/bin/bash

BASE_POLICY_PATH=$PWD/base_policy.json
ADD_POLICY_PATH=$PWD/add_policy.json
REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')

CRD_NAME="assumerole.aws.chatwork"
echo ${REGION}

check_crd() {
  local name=$1
  kubectl get crd $name > /dev/null 2>&1
}

create_crd() {
  local name=$1
  kubectl apply -f $name-crd.yaml
}

get_assume_policy() {
  local role_name=$1
  aws --region=${REGION} iam get-role --role-name $role_name --query 'Role.AssumeRolePolicyDocument'
}

get_controller_role_arn() {
  local cluster_name=$1

  aws --region=${REGION} cloudformation describe-stacks \
    --stack-name ${cluster_name} \
    | jq '.Stacks[].Outputs | map( {(.OutputKey):(.OutputValue)} ) | add | .ControllerIAMRoleArn' -r
}

check_assume_policy() {
  local policy=$1
  local role_arn=$2
  grep ${role_arn} $policy >/dev/null
}

create_assume_policy() {
  local role_arn=$1
  cat << EOS
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "",
            "Effect": "Allow",
            "Principal": {
                "AWS": "${role_arn}"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOS
}
merge_assume_policy() {
  jq -s '.[0].Statement = [.[].Statement[]] | .[0]' ${BASE_POLICY_PATH} ${ADD_POLICY_PATH}
}

update_assume_policy() {
  local role_name=$1
  local cluster_name=$2
  local merge_policy_path=merge_assume_policy.json

  get_assume_policy $role_name > $BASE_POLICY_PATH
  create_assume_policy $(get_controller_role_arn $cluster_name) > $ADD_POLICY_PATH

  merge_assume_policy > ${merge_policy_path}
  #cat ${BASE_POLICY_PATH}
  #cat ${ADD_POLICY_PATH}
  cat ${merge_policy_path}
  aws --region ${REGION} iam update-assume-role-policy --role-name ${role_name} \
      --policy-document file://${merge_policy_path}
}

ensure_assume_policy() {
  if [ $# -eq 2 ] ;then
    local role_name=$1
    local cluster_name=$2

    local policy_path=$PWD/assume_policy.json
    get_assume_policy ${role_name} > $policy_path
    local role_arn=$(get_controller_role_arn ${cluster_name})

    if ! check_assume_policy $policy_path $role_arn; then
      echo "Role not found in ${role_name} assume policy"
      echo "Update ${role_name} assume policy"
      update_assume_policy ${role_name} ${cluster_name}
    else
      echo "Role found in ${role_name} assume policy"
    fi
  else
    echo "Error get ${CRD_NAME} resource"
  fi
}

while :; do
  if ! check_crd ${CRD_NAME}; then
    echo "Create CRD: ${CRD_NAME}"
    create_crd ${CRD_NAME}
    sleep 3
    continue
  fi

  for namespace in $(kubectl get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.end}'); do
    echo "Check Namespace: ${namespace}"
    for r in $(kubectl get ${CRD_NAME} -n ${namespace} -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.end}'); do
      echo "Check $r ..."
      ensure_assume_policy $(kubectl get -n ${namespace} ${CRD_NAME} $r -o jsonpath='{.spec.role_name}{"\t"}{.spec.cluster_name}')
    done
  done

done
