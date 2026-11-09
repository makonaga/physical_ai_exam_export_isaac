# Isaac on AWS - SageMaker Studio セットアップガイド

このドキュメントでは、Isaac EC2 と同じ VPC 内に SageMaker Studio ドメインを作成し、Studio のターミナルから
EC2 に SSH（ポート 22）で接続できることを確認する手順を説明します。
作り方は weaviate_on_aws の `06_sagemaker_studio_setup.md` と同じです（`VpcOnly` モード）。

## 前提条件

- [01_vpc_setup.md](./01_vpc_setup.md) 〜 [04_ec2_deployment.md](./04_ec2_deployment.md) を完了していること
- Isaac EC2 が起動していること（ステップ5の SSH 確認で使う）

```bash
source ~/isaac-oregon-vpc-info.txt && export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2 && echo "SageMaker SG: $SAGEMAKER_SG_ID"
```

---

## ステップ1: SageMaker Studio ドメインの作成

実行ロールは [03_iam_policies.md](./03_iam_policies.md) で作成した `isaac-sagemaker-execution-role`、
セキュリティグループは [02_security_groups.md](./02_security_groups.md) で作成した `isaac-oregon-sagemaker-sg` を使います。
Studio のインスタンスも AZ によって空きがないことがあるため、プライベートサブネットは 4 つとも指定します。

```bash
DOMAIN_ARN=$(aws sagemaker create-domain --domain-name isaac-sagemaker-domain --auth-mode IAM --default-user-settings "{\"ExecutionRole\": \"arn:aws:iam::${AWS_ACCOUNT_ID}:role/isaac-sagemaker-execution-role\", \"SecurityGroups\": [\"$SAGEMAKER_SG_ID\"]}" --subnet-ids $PRIVATE_SUBNET_1A $PRIVATE_SUBNET_1C $PRIVATE_SUBNET_1B $PRIVATE_SUBNET_1D --vpc-id $VPC_ID --app-network-access-type VpcOnly --tags Key=Project,Value=IsaacOnAWS --query 'DomainArn' --output text) && DOMAIN_ID=${DOMAIN_ARN##*/} && echo "Domain: $DOMAIN_ID"
```

`InService` になるまで待ちます（検証時は約 2 分）。`Failed` の場合は止まります。

```bash
while true; do S=$(aws sagemaker describe-domain --domain-id $DOMAIN_ID --query 'Status' --output text); echo "$S"; [ "$S" = "InService" ] || [ "$S" = "Failed" ] && break; sleep 20; done
```

---

## ステップ2: ユーザープロファイルの作成

```bash
aws sagemaker create-user-profile --domain-id $DOMAIN_ID --user-profile-name isaac-user --user-settings "{\"ExecutionRole\": \"arn:aws:iam::${AWS_ACCOUNT_ID}:role/isaac-sagemaker-execution-role\", \"SecurityGroups\": [\"$SAGEMAKER_SG_ID\"]}"
```

```bash
cat >> ~/isaac-oregon-vpc-info.txt << EOF
DOMAIN_ID=$DOMAIN_ID
USER_PROFILE=isaac-user
EOF
```

---

## ステップ3: セキュリティグループの再確認

`VpcOnly` のドメインを作ると、SageMaker が Studio のホームフォルダ（EFS）用のセキュリティグループを 2 つ、VPC に自動で追加します。
構成監査の対象になるので、[02_security_groups.md](./02_security_groups.md) と同じ確認をもう一度行います。

```bash
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[*].{Name:GroupName,Id:GroupId,Inbound:IpPermissions[*].{Proto:IpProtocol,From:FromPort,To:ToPort,Cidr:IpRanges[*].CidrIp,SG:UserIdGroupPairs[*].GroupId}}' --output json
```

自動で追加されるセキュリティグループ（検証時）:

| セキュリティグループ | インバウンド |
|---------------------|-------------|
| security-group-for-inbound-nfs-{DomainID} | TCP 2049（NFS）、988、1018〜1023: すべて下の outbound-nfs SG から |
| security-group-for-outbound-nfs-{DomainID} | なし |

どちらも「特定のセキュリティグループからだけ許可」になっており、セキュリティポリシーに沿っています。
SageMaker が管理するものなので、手で変更・削除しないでください。

0.0.0.0/0 からのインバウンドがないことを確認します（6 つとも空であれば OK）。

```bash
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[*].IpPermissions[?contains(IpRanges[*].CidrIp, `0.0.0.0/0`)]' --output json
```

---

## ステップ4: Studio を開いて秘密鍵を置く

1. AWS コンソールの SageMaker → ドメイン → `isaac-sagemaker-domain` → ユーザー `isaac-user` の「起動」→「Studio」で開きます。
2. JupyterLab のスペースを作成し、インスタンスを ml.t3.medium にして起動します（SSH で EC2 を操作するだけなら十分です）。
3. ローカル PC で、秘密鍵をいったんデスクトップにコピーします（macOS の `~/.ssh` はファイル選択画面に出ない隠しフォルダのため）。

```bash
cp ~/.ssh/isaac-key.pem ~/Desktop/
```

4. JupyterLab の左のファイル画面のアップロードボタンで、デスクトップの `isaac-key.pem` をアップロードします。
5. ローカル PC のデスクトップのコピーを消します。

```bash
rm -f ~/Desktop/isaac-key.pem
```

6. JupyterLab のターミナル（ランチャーの「Terminal」）で、秘密鍵を `~/.ssh` に移します。
   Studio のホームフォルダ（EFS）に保存されるので、スペースを停止・再起動しても残ります。

```bash
mkdir -p ~/.ssh && mv ~/isaac-key.pem ~/.ssh/ && chmod 400 ~/.ssh/isaac-key.pem && ls -l ~/.ssh/isaac-key.pem
```

`-r--------` で始まる行が表示されれば OK です。

---

## ステップ5: Studio から EC2 に SSH する

JupyterLab のターミナルで実行します。ssh コマンドがあることを確認します（検証時は `/usr/bin/ssh` が最初から入っていました）。

```bash
command -v ssh || (sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client && command -v ssh)
```

EC2 のプライベート IP は起動のたびに変わります。ローカル PC で次のように確認します。

```bash
aws ec2 describe-instances --filters "Name=tag:Name,Values=isaac-server" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,Placement.AvailabilityZone]' --output text
```

Studio のターミナルから SSH して、GPU の名前を表示させます（`<EC2のプライベートIP>` を置き換えます）。

```bash
ssh -i ~/.ssh/isaac-key.pem -o StrictHostKeyChecking=accept-new ubuntu@<EC2のプライベートIP> nvidia-smi --query-gpu=name --format=csv,noheader
```

検証時の出力:

```
Warning: Permanently added '<EC2のプライベートIP>' (ED25519) to the list of known hosts.
NVIDIA L40S
```

`NVIDIA L40S` と表示されれば、SageMaker Studio のセキュリティグループから EC2 の 22 番への通信が通っています。

---

## ステップ6: 使い終わったら

JupyterLab のスペースは起動している間課金されます。使わないときは Studio の画面でスペースを停止します。

---

## トラブルシューティング

### SSH がタイムアウトする

1. `isaac-oregon-isaac-sg` に、`isaac-oregon-sagemaker-sg` からの TCP 22 が許可されているか（[02_security_groups.md](./02_security_groups.md)）
2. ユーザープロファイルのセキュリティグループが `isaac-oregon-sagemaker-sg` になっているか（ステップ2）
3. EC2 が起動しているか、プライベート IP が合っているか（起動のたびに変わる）

### REMOTE HOST IDENTIFICATION HAS CHANGED と表示される

EC2 を作り直したときに、以前と同じプライベート IP が割り当てられると表示されます。古い記録を消してから接続し直します。

```bash
ssh-keygen -R <EC2のプライベートIP>
```

---

## 次のステップ

[06_isaac_install.md](./06_isaac_install.md) に進み、EC2 に Isaac Sim・Isaac Lab・LeIsaac を導入します。
