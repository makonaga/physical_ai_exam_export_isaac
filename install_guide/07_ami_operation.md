# Isaac on AWS - AMI での保存と起動（日々の運用）

このドキュメントでは、Isaac EC2 の環境を AMI に保存して EC2 を削除し、次回は AMI から起動する運用の手順を説明します。

## なぜ停止・再開ではなく AMI を使うのか

EC2 のディスク（EBS）は作成した AZ から動かせないため、停止した EC2 は同じ AZ でしか起動できません。
g6e.2xlarge は空きが少なく、検証時は停止した EC2（us-west-2d）を起動しようとして `InsufficientInstanceCapacity` で起動できませんでした。

AMI はリージョン単位で使えるので、AMI から起動すれば、そのとき空きのある AZ を選べます。

| 運用 | 内容 |
|------|------|
| 作業の終わり | 環境を変えた場合は AMI を作り直す → EC2 を削除する（停止ではなく削除） |
| 次の作業の始め | 最新の AMI から、空きのある AZ を順に試して EC2 を起動する |
| 注意 | 起動のたびにプライベート IP が変わる。EC2 の中に置いたデータは削除で消えるので、成果物は S3 に保存する |

---

## 作業の終わり: AMI の作成と EC2 の削除

### ステップ1: EC2 から抜ける

JupyterLab のターミナル（EC2 の中）で `exit` を 2 回入力します（1 回目で tmux を終了、2 回目で EC2 から抜ける）。

### ステップ2: AMI の作成（ローカル PC）

```bash
source ~/isaac-oregon-vpc-info.txt && export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2 && echo "Instance: $ISAAC_INSTANCE_ID"
```

ディスクの中身を正しく保存するため、EC2 は自動で再起動されます。AMI の ID は保存ファイルに追記します（後から追記した値が使われます）。

```bash
AMI_NAME="isaac-server-$(date +%Y%m%d-%H%M)" && ISAAC_AMI_ID=$(aws ec2 create-image --instance-id $ISAAC_INSTANCE_ID --name "$AMI_NAME" --description "Isaac Sim 5.1 + Isaac Lab 2.3.0 (LeIsaac)" --tag-specifications 'ResourceType=image,Tags=[{Key=Name,Value=isaac-server},{Key=Project,Value=IsaacOnAWS}]' 'ResourceType=snapshot,Tags=[{Key=Name,Value=isaac-server},{Key=Project,Value=IsaacOnAWS}]' --query 'ImageId' --output text) && echo "ISAAC_AMI_ID=$ISAAC_AMI_ID" >> ~/isaac-oregon-vpc-info.txt && echo "AMI: $ISAAC_AMI_ID ($AMI_NAME)"
```

### ステップ3: AMI ができあがるまで待つ

30 秒ごとに状態を表示し、`available`（完成）か `failed`（失敗）で止まります。
初回は使用中のデータ全体をコピーするため時間がかかります（検証時は約 50 分）。

```bash
while true; do S=$(aws ec2 describe-images --image-ids $ISAAC_AMI_ID --query 'Images[0].State' --output text); echo "$(date +%H:%M:%S) $S"; [ "$S" = "available" ] || [ "$S" = "failed" ] && break; sleep 30; done
```

進み具合（%）を見たいときは、スナップショットの状態を表示します。

```bash
SNAPSHOT_ID=$(aws ec2 describe-images --image-ids $ISAAC_AMI_ID --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text) && aws ec2 describe-snapshots --snapshot-ids $SNAPSHOT_ID --query 'Snapshots[0].[SnapshotId,State,Progress,VolumeSize]' --output text
```

### ステップ4: EC2 の削除

**`available` になってから**削除します。削除は元に戻せません。
EC2 を消すとディスクも一緒に消える設定（`True`）になっていることを確認します。

```bash
aws ec2 describe-instances --instance-ids $ISAAC_INSTANCE_ID --query 'Reservations[0].Instances[0].[InstanceId,State.Name,BlockDeviceMappings[0].Ebs.DeleteOnTermination]' --output text
```

```bash
aws ec2 terminate-instances --instance-ids $ISAAC_INSTANCE_ID > /dev/null && aws ec2 wait instance-terminated --instance-ids $ISAAC_INSTANCE_ID && echo "削除しました"
```

### ステップ5: SageMaker Studio の JupyterLab を停止する

Studio の画面で JupyterLab のスペースを停止します（起動している間課金されるため）。

---

## 次の作業の始め: AMI から EC2 を起動する（未検証）

> 以下は次回に検証する予定の手順です。

保存ファイルを読み込みます。`ISAAC_AMI_ID` が最新の AMI になっていることを確認します。

```bash
source ~/isaac-oregon-vpc-info.txt && export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2 && echo "AMI: $ISAAC_AMI_ID"
```

[04_ec2_deployment.md](./04_ec2_deployment.md) のステップ3と同じく、4 つのプライベートサブネットを順に試して起動します（AMI を変えただけ）。
ディスクの大きさは AMI に記録されているので指定しません。

```bash
ISAAC_INSTANCE_ID=""; for i in 1 2 3 4 5; do for s in $PRIVATE_SUBNET_1A $PRIVATE_SUBNET_1B $PRIVATE_SUBNET_1C $PRIVATE_SUBNET_1D; do ISAAC_INSTANCE_ID=$(aws ec2 run-instances --image-id $ISAAC_AMI_ID --instance-type g6e.2xlarge --key-name isaac-key --security-group-ids $ISAAC_SG_ID --subnet-id $s --iam-instance-profile Name=isaac-ec2-profile --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=isaac-server},{Key=Project,Value=IsaacOnAWS}]' --query 'Instances[0].InstanceId' --output text) && break 2; done; echo "空きがないため 30 秒後にやり直します（$i/5）"; sleep 30; done; echo "Instance: $ISAAC_INSTANCE_ID"
```

起動を待ち、プライベート IP と AZ を確認して保存ファイルに追記します。

```bash
aws ec2 wait instance-running --instance-ids $ISAAC_INSTANCE_ID && ISAAC_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids $ISAAC_INSTANCE_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text) && aws ec2 describe-instances --instance-ids $ISAAC_INSTANCE_ID --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress,Placement.AvailabilityZone]' --output text && cat >> ~/isaac-oregon-vpc-info.txt << EOF
ISAAC_INSTANCE_ID=$ISAAC_INSTANCE_ID
ISAAC_PRIVATE_IP=$ISAAC_PRIVATE_IP
EOF
```

そのあと、SageMaker Studio の JupyterLab を起動し、表示されたプライベート IP に SSH します
（[05_sagemaker_studio_setup.md](./05_sagemaker_studio_setup.md) のステップ5）。

---

## 費用の目安

| 項目 | 目安 |
|------|------|
| AMI（EBS スナップショット） | us-west-2 で 1GB あたり月 0.05 ドル。課金はディスクの大きさ（200GB）ではなく保存されたデータ量。初回は 80〜100GB 程度の見込みで、月 4〜5 ドル程度 |
| AMI を作り直したとき | 2 回目以降は変わった部分だけが増える。残す世代を絞れば（最新と 1 つ前など）月 5〜7 ドル程度の見込み |

スナップショットの実際の大きさは次で確認できます（値が取れない場合は `0.0 GB` と表示されます）。

```bash
SNAPSHOT_ID=$(aws ec2 describe-images --image-ids $ISAAC_AMI_ID --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text) && aws ec2 describe-snapshots --snapshot-ids $SNAPSHOT_ID --query 'Snapshots[0].FullSnapshotSizeInBytes' --output text | awk '{printf "%.1f GB\n", $1/1024/1024/1024}'
```

EC2 を削除しても、NAT Gateway とそのパブリック IP、インターフェース型の VPC エンドポイント、S3、Studio のホームフォルダ（EFS）は
課金が続きます。
