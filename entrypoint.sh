#!/bin/bash

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')

CRD_NAME="assumerole.aws.chatwork"

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
  local base_policy_path=$2
  aws --region=${REGION} iam get-role --role-name $role_name --query 'Role.AssumeRolePolicyDocument' > ${base_policy_path}
}

get_controller_role_arn() {
  local cluster_name=$1

  aws --region=${REGION} cloudformation describe-stacks \
    --stack-name ${cluster_name} \
    | jq '.Stacks[].Outputs | map( {(.OutputKey):(.OutputValue)} ) | add | .ControllerIAMRoleArn' -r
}

check_assume_policy() {
  local role_arn=$1
  local base_policy_path=$2
  cat ${base_policy_path} | jq -r ".Statement[] | .Principal | select(.AWS==\"${role_arn}\")" | grep ${role_arn} > /dev/null
}

remove_invalid_role() {
  local tmpfile=$(mktemp)
  local role_name=$1
  local base_policy_path=$2

  cp ${base_policy_path} ${tmpfile}

  #cat ${tmpfile} | jq 'del(.Statement[] | .Principal | .AWS | strings | select(test("^(?!arn:)"))) | del(.Statement[] | select(.Principal == {}))' > ${base_policy_path}
  cat ${tmpfile} | \
  jq 'def notArn: . | has("AWS") and (.AWS | test("^arn:") | not);
      def hasOne: keys | length == 1;
      del(.Statement[] | select(.Principal | notArn and hasOne)) | del(.Statement[].Principal | select(notArn) | .AWS)' > ${base_policy_path}

  cmp <(jq -cS . ${tmpfile}) <(jq -cS . ${base_policy_path})

  if [ $? -ne 0 ]; then
    echo "remove invalid role_arn"

    aws --region ${REGION} iam update-assume-role-policy --role-name ${role_name} \
        --policy-document file://${base_policy_path}

    if [ $? -eq 0 ];then
      echo "remove invalid role in ${role_name}"
      cat ${base_policy_path}
    fi

  else
    echo "This role got valid assume policy"
  fi
}

create_assume_policy() {
  local principal_key=$1
  local principal_value=$2
  local add_policy_path=$3
  cat << EOS >${add_policy_path}
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "",
            "Effect": "Allow",
            "Principal": {
                "${principal_key}": "${principal_value}"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOS
}

merge_assume_policy() {
  local merge_policy_path=$1
  local base_policy_path=$2
  local add_policy_path=$3
  jq -s '.[0].Statement = [.[].Statement[]] | .[0]' ${base_policy_path} ${add_policy_path} > ${merge_policy_path}
}

add_assume_policy() {
  local role_name=$1
  local cluster_name=$2
  local base_policy_path=$3
  local add_policy_path=$4
  local merge_policy_path=merge_assume_policy.json

  create_assume_policy "AWS" $(get_controller_role_arn $cluster_name) ${add_policy_path}

  merge_assume_policy ${merge_policy_path} ${base_policy_path} ${add_policy_path}
  aws --region ${REGION} iam update-assume-role-policy --role-name ${role_name} \
      --policy-document file://${merge_policy_path}

  if [ $? -eq 0 ]; then
    rm -f ${base_policy_path}
    rm -f ${add_policy_path}
    rm -f ${merge_policy_path}
  fi
}

ensure_assume_policy() {
  if [ $# -eq 2 ] ;then
    local role_arn=$1
    local cluster_name=$2
    local role_name=${role_arn##*/}
    local base_policy_path="./base_policy_path_$$.json"
    local add_policy_path=$(mktemp)
    local controller_role_arn=$(get_controller_role_arn ${cluster_name})

    echo "role_arn: ${role_arn}"
    echo "cluster_name: ${cluster_name}"
    echo "role_name: ${role_name}"
    echo "controller_role_arn: ${controller_role_arn}"

    while :; do
      cp /dev/null ${base_policy_path}
      get_assume_policy ${role_name} ${base_policy_path}
      sleep 3
      if [ -s ${base_policy_path} ]; then
        echo "role_name: ${role_name} assume policy"
        cat ${base_policy_path}
        break
      else
        echo "ERROR get_assume_policy ${role_name}"
      fi
    done

    remove_invalid_role ${role_name} ${base_policy_path}

    echo "check assume policy..."
    if ! check_assume_policy ${controller_role_arn} ${base_policy_path}; then
      echo "Role not found in ${role_arn} assume policy"
      echo "Update ${role_arn} assume policy"
      add_assume_policy ${role_name} ${cluster_name} ${base_policy_path} ${add_policy_path}
      rm ${base_policy_path}
    else
      echo "Role found ${controller_role_arn} in ${role_arn} assume policy"
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
    if kubectl get ar --all-namespaces | grep -v "No resources found." > /dev/null; then
      for r in $(kubectl get ${CRD_NAME} -n ${namespace} -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.end}'); do
        echo "Napespace: ${namespace} Check 'kind:AssumeRole' $r ..."
        ensure_assume_policy $(kubectl get -n ${namespace} ${CRD_NAME} $r -o jsonpath='{.spec.role_arn}{"\t"}{.spec.cluster_name}')
      done
    else
     echo "No assumerole resource"
    fi
  done
  sleep 3
done
