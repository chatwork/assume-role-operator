# What is purpose of this operator?

This operator is avalable for kubernetes controller role or specified role to add role to assume role policy for kiam.


# Getting Started

## If you use kube-aws, controller role name strict

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

## Apply Helm Chart

Before helm chart install, you need to annotation to namespace.
FYI: https://github.com/uswitch/kiam#overview

```
$ kubectl apply -f namespace.yaml
```

And install helm chart
```
$ cd chart
$ helm install chatwork/assume-role-operator --namespace <NAMESPACE> --set awsRoleArn="arn:aws:iam::XXXXX:role/assume-role-operator_role"
```

chart: https://github.com/chatwork/charts/assume-role-operator

This chart(deployment) creates CRD(aws.chatwork).

# About Assumerole CRD

If you use Assumerole CRD, you need to create manifest, and apply.

If you use kube-aws:

```
apiVersion: "aws.chatwork/v1alpha1"
kind: AssumeRole
metadata:
  name: assume-role-test
spec:
  # same kube-aws clusterName
  cluster_name: <CLUSTER_NAME>
  role_arn: <ROLE_ARN>
```

else:

```
apiVersion: "aws.chatwork/v1alpha1"
kind: AssumeRole
metadata:
  name: assume-role-test
spec:
  role_arn: <ROLE_ARN>
  assume_role_arn: <ASSUME_ROLE_ARN>
```

`assume_role_arn` is added to the `role_arn`'s assume policy.

chart: https://github.com/chatwork/charts/assume-role-crd

This CRD will do the following.
- get the cluster controller role name from cloudformation
  - kube-aws use cloudformation for kubernetes cluster
- add controller role to assume policy for ```role_arn```
