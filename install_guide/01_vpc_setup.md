# Isaac on AWS - VPC構築ガイド

このドキュメントでは、Isaac 用の EC2 を置く専用 VPC を構築する手順を説明します。
作りは weaviate_on_aws の `01_vpc_setup.md` と同じです（パブリックサブネット 2 つ、NAT Gateway、プライベートサブネット、VPC エンドポイント）。
違いは、g6e.2xlarge の空きがある AZ で起動できるよう、プライベートサブネットを 4 つの AZ に作ることです。

すべてのコマンドは**同じターミナル**で続けて実行します（作成した ID を変数に入れて次のコマンドで使うため）。

---

## ステップ0: 事前確認

AWS の認証情報を確認します。

```bash
aws sts get-caller-identity
```

作業するリージョンを設定します。

```bash
export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2
```

g6e.2xlarge が使える AZ を確認します（2026-11-04 時点では us-west-2a・2b・2c・2d）。

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=g6e.2xlarge --query 'InstanceTypeOfferings[].Location' --output text
```

G 系インスタンスの vCPU の上限を確認します。g6e.2xlarge（8 vCPU）を起動するには 8 以上が必要です。

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --query 'Quota.Value'
```

既存の VPC の CIDR を確認し、新しい VPC の CIDR（172.29.0.0/16）と重ならないことを確かめます。

```bash
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table
```

---

## ステップ1: VPCの作成

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 172.29.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=isaac-oregon-vpc},{Key=Project,Value=IsaacOnAWS}]' --query 'Vpc.VpcId' --output text) && echo "VPC: $VPC_ID"
```

VPC エンドポイントのプライベート DNS に必要な DNS 設定を有効化します。

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support && aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
```

---

## ステップ2: インターネットゲートウェイの作成とアタッチ

```bash
IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=isaac-oregon-igw},{Key=Project,Value=IsaacOnAWS}]' --query 'InternetGateway.InternetGatewayId' --output text) && aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID && echo "IGW: $IGW_ID"
```

---

## ステップ3: サブネットの作成

パブリックサブネット 2 つ（NAT Gateway 用）と、プライベートサブネット 2 つを作ります（weaviate と同じ us-west-2a と 2c）。
プライベートサブネットはステップ6でさらに 2 つ追加します。

```bash
PUBLIC_SUBNET_1A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.29.0.0/20 --availability-zone us-west-2a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=isaac-oregon-subnet-public1-us-west-2a},{Key=Project,Value=IsaacOnAWS}]' --query 'Subnet.SubnetId' --output text) && echo "Public 1a: $PUBLIC_SUBNET_1A"
```

```bash
PUBLIC_SUBNET_1C=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.29.16.0/20 --availability-zone us-west-2c --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=isaac-oregon-subnet-public2-us-west-2c},{Key=Project,Value=IsaacOnAWS}]' --query 'Subnet.SubnetId' --output text) && echo "Public 1c: $PUBLIC_SUBNET_1C"
```

```bash
PRIVATE_SUBNET_1A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.29.128.0/20 --availability-zone us-west-2a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=isaac-oregon-subnet-private1-us-west-2a},{Key=Project,Value=IsaacOnAWS}]' --query 'Subnet.SubnetId' --output text) && echo "Private 1a: $PRIVATE_SUBNET_1A"
```

```bash
PRIVATE_SUBNET_1C=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.29.144.0/20 --availability-zone us-west-2c --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=isaac-oregon-subnet-private2-us-west-2c},{Key=Project,Value=IsaacOnAWS}]' --query 'Subnet.SubnetId' --output text) && echo "Private 1c: $PRIVATE_SUBNET_1C"
```

**セキュリティ要件**: パブリック IP の自動割り当ては、すべてのサブネットで無効にします（作成時の既定値のまま変更しない）。
`MapPublicIpOnLaunch` がすべて `False` であることを確認します。

```bash
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' --output table
```

ここまでの ID を保存します。

```bash
cat > ~/isaac-oregon-vpc-info.txt << EOF
# Isaac on AWS - Oregon VPC情報（作成日時: $(date)）
VPC_ID=$VPC_ID
IGW_ID=$IGW_ID
PUBLIC_SUBNET_1A=$PUBLIC_SUBNET_1A
PUBLIC_SUBNET_1C=$PUBLIC_SUBNET_1C
PRIVATE_SUBNET_1A=$PRIVATE_SUBNET_1A
PRIVATE_SUBNET_1C=$PRIVATE_SUBNET_1C
EOF
```

---

## ステップ4: Elastic IPの確保とNAT Gatewayの作成

NAT Gateway は作成した時点から時間単位の課金が始まります。

```bash
EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=isaac-oregon-eip-nat},{Key=Project,Value=IsaacOnAWS}]' --query 'AllocationId' --output text) && echo "EIP: $EIP_ALLOC_ID"
```

パブリックサブネット 1a に NAT Gateway を作ります。タグの `ResourceType` は `natgateway` です（`nat-gateway` ではエラーになります）。

```bash
NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id $PUBLIC_SUBNET_1A --allocation-id $EIP_ALLOC_ID --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=isaac-oregon-nat},{Key=Project,Value=IsaacOnAWS}]' --query 'NatGateway.NatGatewayId' --output text) && echo "NAT Gateway: $NAT_GW_ID"
```

使えるようになるまで数分待ちます。

```bash
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID && echo "NAT Gateway: available"
```

---

## ステップ5: ルートテーブルの作成と設定

### パブリックルートテーブル（インターネットゲートウェイへのルート）

```bash
PUBLIC_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=isaac-oregon-rtb-public},{Key=Project,Value=IsaacOnAWS}]' --query 'RouteTable.RouteTableId' --output text) && echo "Public RT: $PUBLIC_RT_ID"
```

```bash
aws ec2 create-route --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID && aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_1A --route-table-id $PUBLIC_RT_ID && aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_1C --route-table-id $PUBLIC_RT_ID
```

### プライベートルートテーブル（NAT Gateway へのルート）

```bash
PRIVATE_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=isaac-oregon-rtb-private},{Key=Project,Value=IsaacOnAWS}]' --query 'RouteTable.RouteTableId' --output text) && echo "Private RT: $PRIVATE_RT_ID"
```

```bash
aws ec2 create-route --route-table-id $PRIVATE_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID && aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_1A --route-table-id $PRIVATE_RT_ID && aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_1C --route-table-id $PRIVATE_RT_ID
```

### 確認

`isaac-oregon-rtb-public` の 0.0.0.0/0 が `igw-...`、`isaac-oregon-rtb-private` の 0.0.0.0/0 が `nat-...` であることを確認します。
名前のないルートテーブルは VPC 作成時に自動でできるメインルートテーブルで、どのサブネットにも関連付けないので変更不要です。

```bash
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[*].[RouteTableId,Tags[?Key==`Name`].Value|[0],Routes[?GatewayId!=`local`].[DestinationCidrBlock,GatewayId,NatGatewayId]]' --output json
```

```bash
cat >> ~/isaac-oregon-vpc-info.txt << EOF
EIP_ALLOC_ID=$EIP_ALLOC_ID
NAT_GW_ID=$NAT_GW_ID
PUBLIC_RT_ID=$PUBLIC_RT_ID
PRIVATE_RT_ID=$PRIVATE_RT_ID
EOF
```

---

## ステップ6: プライベートサブネットの追加（us-west-2b・2d）

g6e.2xlarge は AZ ごとに空きがなくなることがあります（検証時は us-west-2a・2c とも `InsufficientInstanceCapacity` が続き、
2d で起動できました）。起動できる AZ を増やすため、プライベートサブネットを us-west-2b と 2d にも作り、
プライベートルートテーブルに関連付けます。

```bash
PRIVATE_SUBNET_1B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.29.160.0/20 --availability-zone us-west-2b --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=isaac-oregon-subnet-private3-us-west-2b},{Key=Project,Value=IsaacOnAWS}]' --query 'Subnet.SubnetId' --output text) && aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_1B --route-table-id $PRIVATE_RT_ID && echo "Private 1b: $PRIVATE_SUBNET_1B"
```

```bash
PRIVATE_SUBNET_1D=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.29.176.0/20 --availability-zone us-west-2d --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=isaac-oregon-subnet-private4-us-west-2d},{Key=Project,Value=IsaacOnAWS}]' --query 'Subnet.SubnetId' --output text) && aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_1D --route-table-id $PRIVATE_RT_ID && echo "Private 1d: $PRIVATE_SUBNET_1D"
```

6 つのサブネットすべてで `MapPublicIpOnLaunch` が `False` であることを確認します。

```bash
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' --output table
```

```bash
cat >> ~/isaac-oregon-vpc-info.txt << EOF
PRIVATE_SUBNET_1B=$PRIVATE_SUBNET_1B
PRIVATE_SUBNET_1D=$PRIVATE_SUBNET_1D
EOF
```

---

## ステップ7: VPCエンドポイントの作成

weaviate の `01_vpc_setup.md` ステップ6 と同じ作り方です。作るのは S3（ゲートウェイ型）、CloudWatch Logs、SageMaker API、
SageMaker Runtime（インターフェース型）の 4 つです。weaviate にある Bedrock Runtime と ECR は、この構成では使わないので作りません。

### VPCエンドポイント用セキュリティグループ（VPC の CIDR からの 443 番だけを許可）

```bash
VPCE_SG_ID=$(aws ec2 create-security-group --group-name isaac-oregon-vpce-sg --description "Security group for VPC Endpoints - Isaac on AWS" --vpc-id $VPC_ID --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=isaac-oregon-vpce-sg},{Key=Project,Value=IsaacOnAWS}]' --query 'GroupId' --output text) && echo "VPCE SG: $VPCE_SG_ID"
```

```bash
aws ec2 authorize-security-group-ingress --group-id $VPCE_SG_ID --protocol tcp --port 443 --cidr 172.29.0.0/16
```

### S3（ゲートウェイ型）: EC2 と Studio のデータ受け渡しに使う

```bash
S3_VPCE_ID=$(aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.us-west-2.s3 --route-table-ids $PUBLIC_RT_ID $PRIVATE_RT_ID --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=isaac-oregon-vpce-s3},{Key=Project,Value=IsaacOnAWS}]' --query 'VpcEndpoint.VpcEndpointId' --output text) && echo "S3 VPCE: $S3_VPCE_ID"
```

### CloudWatch Logs

```bash
LOGS_VPCE_ID=$(aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --vpc-endpoint-type Interface --service-name com.amazonaws.us-west-2.logs --subnet-ids $PRIVATE_SUBNET_1A $PRIVATE_SUBNET_1C --security-group-ids $VPCE_SG_ID --private-dns-enabled --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=isaac-oregon-vpce-logs},{Key=Project,Value=IsaacOnAWS}]' --query 'VpcEndpoint.VpcEndpointId' --output text) && echo "Logs VPCE: $LOGS_VPCE_ID"
```

### SageMaker API と SageMaker Runtime: VPC 内の SageMaker Studio が使う

```bash
SAGEMAKER_API_VPCE_ID=$(aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --vpc-endpoint-type Interface --service-name com.amazonaws.us-west-2.sagemaker.api --subnet-ids $PRIVATE_SUBNET_1A $PRIVATE_SUBNET_1C --security-group-ids $VPCE_SG_ID --private-dns-enabled --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=isaac-oregon-vpce-sagemaker-api},{Key=Project,Value=IsaacOnAWS}]' --query 'VpcEndpoint.VpcEndpointId' --output text) && echo "SageMaker API VPCE: $SAGEMAKER_API_VPCE_ID"
```

```bash
SAGEMAKER_RUNTIME_VPCE_ID=$(aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --vpc-endpoint-type Interface --service-name com.amazonaws.us-west-2.sagemaker.runtime --subnet-ids $PRIVATE_SUBNET_1A $PRIVATE_SUBNET_1C --security-group-ids $VPCE_SG_ID --private-dns-enabled --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=isaac-oregon-vpce-sagemaker-runtime},{Key=Project,Value=IsaacOnAWS}]' --query 'VpcEndpoint.VpcEndpointId' --output text) && echo "SageMaker Runtime VPCE: $SAGEMAKER_RUNTIME_VPCE_ID"
```

### 確認

4 つとも State が `available` になることを確認します。インターフェース型は数分 `pending` のままなので、少し待ってから再実行します。

```bash
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[*].[VpcEndpointId,ServiceName,VpcEndpointType,State]' --output table
```

```bash
cat >> ~/isaac-oregon-vpc-info.txt << EOF
VPCE_SG_ID=$VPCE_SG_ID
S3_VPCE_ID=$S3_VPCE_ID
LOGS_VPCE_ID=$LOGS_VPCE_ID
SAGEMAKER_API_VPCE_ID=$SAGEMAKER_API_VPCE_ID
SAGEMAKER_RUNTIME_VPCE_ID=$SAGEMAKER_RUNTIME_VPCE_ID
EOF
```

---

## 次のステップ

[02_security_groups.md](./02_security_groups.md) に進み、Isaac EC2 用と SageMaker Studio 用のセキュリティグループを作成します。
