# Isaac on AWS - EC2デプロイガイド

このドキュメントでは、Isaac 用の EC2 を起動し、SSM Session Manager で接続して GPU と外部への通信を確認する手順を説明します。

## 前提条件

以下のガイドを完了していることを前提とします。

- [01_vpc_setup.md](./01_vpc_setup.md) - VPC 環境の構築
- [02_security_groups.md](./02_security_groups.md) - セキュリティグループの設定
- [03_iam_policies.md](./03_iam_policies.md) - S3 バケットと IAM ロールの設定

```bash
source ~/isaac-oregon-vpc-info.txt && export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2 && echo "ISAAC_SG_ID: $ISAAC_SG_ID"
```

## EC2 の構成

| 項目 | 設定 |
|------|------|
| 名前 | isaac-server |
| インスタンスタイプ | g6e.2xlarge（NVIDIA L40S 48GB、8 vCPU、メモリ 64GB） |
| AMI | Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) の最新版（Amazon 公式。NVIDIA のデータセンター向けドライバ入り） |
| 置き場所 | プライベートサブネット（空きのある AZ。パブリック IP なし） |
| セキュリティグループ | isaac-oregon-isaac-sg |
| IAM | isaac-ec2-profile |
| ディスク | gp3 200GB |
| キーペア | isaac-key（SageMaker Studio から SSH するため） |

起動している間は時間単位で課金されます。使い終わったら AMI に保存して削除します（[07_ami_operation.md](./07_ami_operation.md)）。
停止した EC2 は同じ AZ でしか起動できず、g6e.2xlarge の空きがないと起動できないため、停止・再開の運用はしません。

---

## ステップ1: キーペアの作成

秘密鍵はローカル PC の `~/.ssh/isaac-key.pem` に保存します（作成時にしか取得できないので、なくさないでください）。

```bash
mkdir -p ~/.ssh && aws ec2 create-key-pair --key-name isaac-key --query 'KeyMaterial' --output text > ~/.ssh/isaac-key.pem && chmod 400 ~/.ssh/isaac-key.pem && echo "キーペア作成完了"
```

---

## ステップ2: AMIの取得

```bash
AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) *" "Name=state,Values=available" "Name=architecture,Values=x86_64" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) && echo "AMI: $AMI_ID"
```

ルートデバイス名（ディスクの大きさの指定に使う）を取得し、AMI の名前を確認します。

```bash
ROOT_DEVICE=$(aws ec2 describe-images --image-ids $AMI_ID --query 'Images[0].RootDeviceName' --output text) && aws ec2 describe-images --image-ids $AMI_ID --query 'Images[0].[Name,RootDeviceName]' --output text
```

検証時の出力:

```
Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20261030    /dev/sda1
```

---

## ステップ3: EC2インスタンスの起動

g6e.2xlarge は AZ ごとに空きがなくなることがあり、`InsufficientInstanceCapacity` で起動できないことがあります
（検証時は us-west-2a・2b・2c に空きがなく、2d で起動できました）。
そのため、4 つのプライベートサブネットを順に試し、どれも空いていなければ 30 秒待ってやり直します（最大 5 回）。

```bash
ISAAC_INSTANCE_ID=""; for i in 1 2 3 4 5; do for s in $PRIVATE_SUBNET_1B $PRIVATE_SUBNET_1D $PRIVATE_SUBNET_1A $PRIVATE_SUBNET_1C; do ISAAC_INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type g6e.2xlarge --key-name isaac-key --security-group-ids $ISAAC_SG_ID --subnet-id $s --iam-instance-profile Name=isaac-ec2-profile --block-device-mappings "DeviceName=$ROOT_DEVICE,Ebs={VolumeSize=200,VolumeType=gp3}" --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=isaac-server},{Key=Project,Value=IsaacOnAWS}]' --query 'Instances[0].InstanceId' --output text) && break 2; done; echo "空きがないため 30 秒後にやり直します（$i/5）"; sleep 30; done; echo "Instance: $ISAAC_INSTANCE_ID"
```

`Instance: i-...` と表示されれば起動できています。`Instance:` の後ろが空の場合は、どの AZ にも空きがなかったので、
時間をおいて同じコマンドを実行し直します。

起動するまで待ち、プライベート IP・パブリック IP・インスタンスタイプ・AZ を表示します。
**パブリック IP が `None` であること**を確認します。

```bash
aws ec2 wait instance-running --instance-ids $ISAAC_INSTANCE_ID && aws ec2 describe-instances --instance-ids $ISAAC_INSTANCE_ID --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress,InstanceType,Placement.AvailabilityZone]' --output text
```

検証時の出力（IP は環境によって変わります）:

```
172.29.182.19   None    g6e.2xlarge     us-west-2d
```

---

## ステップ4: 情報の保存

**ローカル PC で**実行します。EC2 の中で実行すると、EC2 のロールには EC2 の情報を読む権限を与えていないため
`UnauthorizedOperation` になります（意図どおりの動作です）。

```bash
ISAAC_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids $ISAAC_INSTANCE_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text) && cat >> ~/isaac-oregon-vpc-info.txt << EOF
KEY_NAME=isaac-key
AMI_ID=$AMI_ID
ISAAC_INSTANCE_ID=$ISAAC_INSTANCE_ID
ISAAC_PRIVATE_IP=$ISAAC_PRIVATE_IP
EOF
```

---

## ステップ5: Session Manager Plugin のインストール（未インストールの場合）

`aws ssm start-session` を実行して `SessionManagerPlugin is not found` と出る場合は、ローカル PC に
Session Manager Plugin を入れます。以下は macOS 用です（Apple シリコン / Intel を自動で判定）。
ほかの OS は AWS のドキュメント「Install the Session Manager plugin for the AWS CLI」を参照してください。

```bash
if [ "$(uname -m)" = "arm64" ]; then SMP_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/session-manager-plugin.pkg"; else SMP_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/session-manager-plugin.pkg"; fi && curl -fsSL "$SMP_URL" -o /tmp/session-manager-plugin.pkg && echo "ダウンロード完了: $SMP_URL"
```

Mac のログインパスワードを聞かれます。

```bash
sudo installer -pkg /tmp/session-manager-plugin.pkg -target /
```

```bash
sudo mkdir -p /usr/local/bin && sudo ln -sf /usr/local/sessionmanagerplugin/bin/session-manager-plugin /usr/local/bin/session-manager-plugin
```

`The Session Manager plugin was installed successfully.` と表示されれば OK です（`command not found` の場合は先に `rehash`）。

```bash
session-manager-plugin
```

```bash
rm -f /tmp/session-manager-plugin.pkg
```

---

## ステップ6: SSM での接続確認

### SSM への登録確認

起動してから SSM に登録されるまで数分かかります。`Online` と表示されれば接続できます
（何も表示されない・`None` の場合は 1〜2 分待って再実行）。

```bash
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$ISAAC_INSTANCE_ID" --query 'InstanceInformationList[0].[PingStatus,PlatformName,PlatformVersion]' --output text
```

検証時の出力:

```
Online  Ubuntu  22.04
```

### SSM で接続

```bash
aws ssm start-session --target $ISAAC_INSTANCE_ID
```

### EC2 内での確認

GPU とドライバを確認します。

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
```

検証時の出力（ドライバ 595.112.07 は Isaac Sim 5.1 の推奨 580.65.06 以上を満たす）:

```
name, driver_version, memory.total [MiB]
NVIDIA L40S, 595.112.07, 46068 MiB
```

NAT Gateway 経由でインターネット（PyPI）に出られることを確認します。

```bash
curl -sI https://pypi.org | head -n1
```

検証時の出力:

```
HTTP/2 200
```

確認が終わったら `exit` で接続を切ります。

---

## トラブルシューティング

### InsufficientInstanceCapacity で起動できない

その AZ に g6e.2xlarge の空きがありません。ステップ3のコマンドは 4 つの AZ を順に試します。
すべて失敗した場合は、時間をおいて実行し直してください。
エラーメッセージの「choosing us-west-2x なら空きがある」は当てにならないことがありました。

### SessionManagerPlugin is not found

ローカル PC に Session Manager Plugin が入っていません。ステップ5で入れてください。

### UnauthorizedOperation（ec2:DescribeInstances）

ステップ4などのローカル PC 用のコマンドを、SSM で接続した EC2 の中で実行しています。`exit` で抜けてから実行してください。

---

## 次のステップ

[05_sagemaker_studio_setup.md](./05_sagemaker_studio_setup.md) に進み、同じ VPC 内に SageMaker Studio ドメインを作って、
Studio から EC2 に SSH できることを確認します。
