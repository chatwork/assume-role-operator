# What is purpose of this operator?

This operator is avalable for kubernetes controller role to assume role using kiam.
Target controller role is only role made from kube-aws.


# Getting Started

## kube-aws controller role name strict

kube-aws(>= 0.11.1) has strict mode for role name that fixes the role name of the controller.
You need to use this mode.

```
controller:
  iam:
    role:
      name: <CONTROLLER_ROLE_NAME>
      strictName: true
```

## Create AWS Role

This operator use aws role and needs to be able to assumed by kubernetes controller role.

This operator needs policy:
```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "iam:GetRole",
                "iam:UpdateAssumeRolePolicy",
                "iam:List*",
                "cloudformation:DescribeStackEvents",
                "cloudformation:DescribeStacks"
            ],
            "Resource": [
                "arn:aws:cloudformation:*:*:stack/*/*",
                "arn:aws:iam::*:role/*"
            ]
        }
    ]
}
```

and assume policy
```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::XXXXXXX:role/<CONTROLLER_ROLE_NAME>",
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

## Apply RBAC and Deployment

ToDo: helm chart

```
kubectl apply -f manifests/rbac.yaml
kubectl apply -f manifests/deployment.yaml
```

This deployment creates CRD(aws.chatwork).

# About CRD

If you use CRD, you need to create manifest, and apply.

```
apiVersion: "aws.chatwork/v1alpha1"
kind: AssumeRole
metadata:
  name: assume-role-test
spec:
  # same kube-aws clusterName
  cluster_name: <CLUSTER_NAME>
  role_name: <ROLE_NAME> # not arn
```

This CRD will do th following.
- get the cluster controller role name from cloudformation
  - kube-aws use cloudformation for kubernetes cluster
- add controller role to ```role_name``` assume policy
