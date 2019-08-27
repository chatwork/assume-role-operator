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

remove_duplication_role() {
  local tmpfile=$(mktemp)
  local role_name=$1
  local base_policy_path=$2

  cp ${base_policy_path} ${tmpfile}

  jq '.Statement = (.Statement | unique)' $tmpfile > ${base_policy_path}

  cmp <(jq -cS . ${tmpfile}) <(jq -cS . ${base_policy_path})

  if [ $? -ne 0 ]; then
    echo "remove duplicate role_arn"

    aws --region ${REGION} iam update-assume-role-policy --role-name ${role_name} \
        --policy-document file://${base_policy_path}

    if [ $? -eq 0 ];then
      echo "remove duplicate role in ${role_name}"
      cat ${base_policy_path}
    fi

  else
    echo "This role has unique assume policy"
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
  tmpfile=$(mktemp)
  jq -s '.[0].Statement = [.[].Statement[]] | .[0]' ${base_policy_path} ${add_policy_path} > $tmpfile
  jq '.Statement = (.Statement | unique)' $tmpfile > ${merge_policy_path}
}

add_assume_policy() {
  local role_arn=$1
  local assume_role_arn=$2
  local base_policy_path=$3
  local add_policy_path=$4
  local merge_policy_path=./merge_assume_policy.json

  create_assume_policy "AWS" ${assume_role_arn} ${add_policy_path}

  merge_assume_policy ${merge_policy_path} ${base_policy_path} ${add_policy_path}
  aws --region ${REGION} iam update-assume-role-policy --role-name ${role_arn} \
      --policy-document file://${merge_policy_path}

  if [ $? -eq 0 ]; then
    rm -f ${base_policy_path}
    rm -f ${add_policy_path}
    rm -f ${merge_policy_path}
  fi
}

ensure_assume_policy() {
  if [ $# -eq 2 ] ;then
    local local_role_arn=$1
    local local_assume_role_arn=$2
    local role_name=${local_role_arn##*/}
    local base_policy_path=$(mktemp)
    local add_policy_path=$(mktemp)

    echo "role_arn: ${local_role_arn}"
    echo "role_name: ${role_name}"
    echo "assume_role_arn: ${local_assume_role_arn}"

    if check_arn_format $local_role_arn && check_arn_format $local_assume_role_arn; then
      while :; do
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
      remove_duplication_role ${role_name} ${base_policy_path}

      echo "check assume policy..."
      if ! check_assume_policy ${local_assume_role_arn} ${base_policy_path}; then
        echo "Role not found in ${local_role_arn} assume policy"
        echo "Update ${local_role_arn} assume policy"
        add_assume_policy ${role_name} ${local_assume_role_arn} ${base_policy_path} ${add_policy_path}
      else
        echo "Role found ${local_assume_role_arn} in ${local_role_arn} assume policy"
      fi
    else
      echo "Error get ${CRD_NAME} resource"
    fi
  else
    echo "invalid arn format role_arn or assume_role_arn"
  fi
}

check_arn_format() {
  local arn=$1

  if echo $arn | grep -e "^arn:aws:iam::.*" > /dev/null ; then
    return 0
  else
    return 1
  fi
}

get_assume_role_arn() {
  local namespace=$1
  local resource=$2
  local cluster_name=$(kubectl get -n ${namespace} ${CRD_NAME} $resource -o jsonpath='{.spec.cluster_name}')
  local local_assume_role_arn=$(kubectl get -n ${namespace} ${CRD_NAME} $resource -o jsonpath='{.spec.assume_role_arn}')

  echo "In get_assume_role_arn"
  echo "cluster_name: ${cluster_name}"
  echo "assume_role_arn: ${local_assume_role_arn}"

  if [ -z "${cluster_name}" ] && [ ! -z "${local_assume_role_arn}" ]; then
      assume_role_arn=${local_assume_role_arn}
  elif [ ! -z "${cluster_name}" ] && [ -z "${local_assume_role_arn}" ]; then
      assume_role_arn=$(get_controller_role_arn ${cluster_name})
  else
      echo "Error ${CRD_NAME} resource"
      echo "cluste_name:${cluster_name} and assume_role_arn:${local_assume_role_arn} are exclusive items"
      return 1
  fi

  return 0
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
        echo "Namespace: ${namespace} Check 'kind:AssumeRole' $r ..."
        role_arn=$(kubectl get -n ${namespace} ${CRD_NAME} $r -o jsonpath='{.spec.role_arn}')
        assume_role_arn=""

        if ! get_assume_role_arn ${namespace} $r; then
          continue
        fi
        ensure_assume_policy ${role_arn} ${assume_role_arn}
      done
    else
     echo "No assumerole resource"
    fi
  done
  sleep 3
done
