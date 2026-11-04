# Isaac on AWS - S3バケットとIAM設定ガイド

このドキュメントでは、EC2 と SageMaker Studio のデータ受け渡しに使う S3 バケットと、
EC2 用・SageMaker Studio 用の IAM ロールを作成する手順を説明します。
作り方は weaviate_on_aws の `03_iam_policies.md`・`04_weaviate_deployment.md`・`06_sagemaker_studio_setup.md` と同じです。

## 事前準備

```bash
source ~/isaac-oregon-vpc-info.txt && export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2 && echo "VPC_ID: $VPC_ID"
```

## 作成するもの

| リソース | 名前 | 内容 |
|---------|------|------|
| S3 バケット | isaac-data-{AccountID} | EC2 と Studio のデータ受け渡し（バージョニング有効） |
| IAM ロール | isaac-ec2-role | EC2 用。SSM 接続と、上のバケットだけへの読み書き |
| インスタンスプロファイル | isaac-ec2-profile | isaac-ec2-role を EC2 に付けるため |
| IAM ロール | isaac-sagemaker-execution-role | SageMaker Studio 用。`AmazonSageMakerFullAccess` と、上のバケットだけへの読み書き |

Studio 用のロールは、Studio で学習したモデルを ③評価のために EC2 へ渡すので、バケットへの書き込みも許可します。

---

## ステップ1: S3バケットの作成

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) && S3_BUCKET_NAME="isaac-data-${AWS_ACCOUNT_ID}" && echo "Bucket: $S3_BUCKET_NAME"
```

```bash
aws s3api create-bucket --bucket $S3_BUCKET_NAME --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION
```

バージョニングを有効化します（上書き・削除した古い版も残り、その分の保管料金がかかります）。

```bash
aws s3api put-bucket-versioning --bucket $S3_BUCKET_NAME --versioning-configuration Status=Enabled
```

```bash
aws s3api head-bucket --bucket $S3_BUCKET_NAME && echo "バケット作成成功"
```

---

## ステップ2: バケットを限定した S3 アクセスポリシーの作成

EC2 用・Studio 用の両方のロールで使います。

```bash
cat > /tmp/isaac-s3-access-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET_NAME}",
        "arn:aws:s3:::${S3_BUCKET_NAME}/*"
      ]
    }
  ]
}
EOF
```

---

## ステップ3: Isaac EC2用IAMロールの作成

### 信頼ポリシー（Trust Policy）

```bash
cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

### IAMロールとポリシー

```bash
aws iam create-role --role-name isaac-ec2-role --assume-role-policy-document file:///tmp/ec2-trust-policy.json --description "IAM role for Isaac EC2 instances" --tags Key=Project,Value=IsaacOnAWS
```

SSM Session Manager で接続するためのマネージドポリシーを付けます。

```bash
aws iam attach-role-policy --role-name isaac-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

```bash
aws iam put-role-policy --role-name isaac-ec2-role --policy-name S3AccessPolicy --policy-document file:///tmp/isaac-s3-access-policy.json
```

### インスタンスプロファイル

```bash
aws iam create-instance-profile --instance-profile-name isaac-ec2-profile && aws iam add-role-to-instance-profile --instance-profile-name isaac-ec2-profile --role-name isaac-ec2-role
```

---

## ステップ4: SageMaker Studio用IAMロールの作成

### 信頼ポリシー（Trust Policy）

```bash
cat > /tmp/sagemaker-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "sagemaker.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

### IAMロールとポリシー

```bash
aws iam create-role --role-name isaac-sagemaker-execution-role --assume-role-policy-document file:///tmp/sagemaker-trust-policy.json --description "SageMaker Studio execution role - Isaac on AWS" --tags Key=Project,Value=IsaacOnAWS
```

```bash
aws iam attach-role-policy --role-name isaac-sagemaker-execution-role --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess
```

```bash
aws iam put-role-policy --role-name isaac-sagemaker-execution-role --policy-name S3AccessPolicy --policy-document file:///tmp/isaac-s3-access-policy.json
```

---

## ステップ5: 確認

各ロールのマネージドポリシーとインラインポリシーを表示します。

```bash
for r in isaac-ec2-role isaac-sagemaker-execution-role; do echo "== $r"; aws iam list-attached-role-policies --role-name $r --query 'AttachedPolicies[].PolicyName' --output text; aws iam list-role-policies --role-name $r --query 'PolicyNames' --output text; done
```

期待される出力:

```
== isaac-ec2-role
AmazonSSMManagedInstanceCore
S3AccessPolicy
== isaac-sagemaker-execution-role
AmazonSageMakerFullAccess
S3AccessPolicy
```

インスタンスプロファイルに `isaac-ec2-role` が入っていることを確認します。

```bash
aws iam get-instance-profile --instance-profile-name isaac-ec2-profile --query 'InstanceProfile.Roles[].RoleName' --output text
```

---

## ステップ6: 情報の保存と一時ファイルの削除

```bash
cat >> ~/isaac-oregon-vpc-info.txt << EOF
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
S3_BUCKET_NAME=$S3_BUCKET_NAME
EC2_ROLE_NAME=isaac-ec2-role
EC2_INSTANCE_PROFILE=isaac-ec2-profile
SAGEMAKER_EXECUTION_ROLE_NAME=isaac-sagemaker-execution-role
EOF
```

```bash
rm -f /tmp/isaac-s3-access-policy.json /tmp/ec2-trust-policy.json /tmp/sagemaker-trust-policy.json
```

---

## IAMポリシー構成サマリー

### isaac-ec2-role (Isaac EC2用)

| ポリシー名 | 種類 | 権限 |
|-----------|------|------|
| AmazonSSMManagedInstanceCore | マネージド | SSM Session Manager 接続 |
| S3AccessPolicy | インライン | isaac-data-{AccountID} バケットへの読み書き |

### isaac-sagemaker-execution-role (SageMaker Studio用)

| ポリシー名 | 種類 | 権限 |
|-----------|------|------|
| AmazonSageMakerFullAccess | マネージド | SageMaker Studio の利用 |
| S3AccessPolicy | インライン | isaac-data-{AccountID} バケットへの読み書き |

---

## 次のステップ

[04_ec2_deployment.md](./04_ec2_deployment.md) に進み、Isaac EC2 を起動します。
