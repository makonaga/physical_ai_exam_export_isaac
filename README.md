# SO-101 食材投入タスク（Isaac Lab 版）

[physical_ai_exam](https://github.com/makonaga/physical_ai_exam) の MuJoCo で行っている処理のうち、
①学習データの生成と③評価を NVIDIA Isaac Lab に置き換える。②学習は今と同じ LeRobot（`lerobot-train`）で行う。

| 処理 | physical_ai_exam | このリポジトリ |
|---|---|---|
| ① 学習データの生成 | MuJoCo（so101-nexus） | Isaac Lab |
| ② 学習 | LeRobot（ACT・SmolVLA） | LeRobot（変更なし） |
| ③ 評価 | MuJoCo（so101-nexus） | Isaac Lab |

## 進捗

| 段階 | 内容 | 状態 |
|---|---|---|
| 0 | SageMaker Studio（JupyterLab）で Isaac Sim が動くかの確認 | そのままでは動かない（下の「参考」）。①③は EC2 で行う方針に変更 |
| 1 | EC2 環境の構築（[install_guide/](install_guide/00_overview.md)） | 01〜04（VPC、セキュリティグループ、S3・IAM、EC2 の起動と SSM 接続）は検証済み。05（SageMaker Studio）・06（Isaac の導入）は未実施 |

## EC2 環境

構築手順は [install_guide/00_overview.md](install_guide/00_overview.md)。セキュリティの構成は
[weaviate_on_aws](https://github.com/makonaga/weaviate_on_aws) と同じ考え方（プライベートサブネット、パブリック IP なし、
インバウンドは必要なセキュリティグループからだけ、SSM Session Manager で接続）。

| 項目 | 内容 |
|---|---|
| リージョン | us-west-2（SageMaker Studio も同じ VPC 内に作る） |
| EC2 | g6e.2xlarge（NVIDIA L40S 48GB）、Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) |
| データの受け渡し | S3 バケット（EC2 と SageMaker Studio の間） |

## 参考: SageMaker Studio で Vulkan を使えなかった記録

Isaac Sim はカメラ画像の描画に Vulkan を使う。SageMaker Studio の JupyterLab では、どの GPU インスタンスでも
コンテナに NVIDIA の描画用ライブラリが渡されておらず、そのままでは Vulkan を使えなかった。

| インスタンス | GPU | `NVIDIA_DRIVER_CAPABILITIES` | Vulkan の設定ファイル・NVIDIA の描画用ライブラリ |
|---|---|---|---|
| ml.g4dn | T4 | compute,utility | なし |
| ml.g5.2xlarge | A10G | compute,utility | なし |
| ml.g6.2xlarge | L4 | compute,utility | なし |
| ml.g6e | L40S | compute,utility | なし |

（ドライバはどれも 595.91.07）

`scripts/setup_vulkan_sagemaker.sh` は、ドライバと同じ版の NVIDIA ドライバ配布ファイルから描画用のライブラリだけを
取り出してホーム配下（`~/.nvidia-gl/`）に置き、Vulkan で GPU が見えるかを調べる（作成したが、EC2 に方針を変えたため未実行）。
AWS・NVIDIA の公式な方法ではなく、描画用のデバイス（`/dev/dri`）はコンテナの中から作れないため、動くかは試すまで分からない。

GPU インスタンスの JupyterLab スペースのターミナルで実行する。

```bash
cd ~/user-default-efs
git clone -b claude/nifty-dirac-110yu5 https://github.com/makonaga/physical_ai_exam_export_isaac.git
cd physical_ai_exam_export_isaac
bash scripts/setup_vulkan_sagemaker.sh
```

- 最後に「成功: Vulkan で NVIDIA の GPU が見えています。」と出れば、Vulkan を使える。
- 「失敗」と出たら、表示された vulkaninfo の出力を見て原因を調べる（全体は `~/.nvidia-gl/<ドライバの版>/vulkaninfo.log`）。
- apt で入れるパッケージ（libvulkan1・vulkan-tools）は再起動で消えるので、スペースを起動するたびに実行する
  （2 回目以降はダウンロードと展開を省く）。
- 使うときは、Isaac Sim を動かすシェルで `source ~/.nvidia-gl/env.sh` を実行する。MuJoCo の描画も GPU（EGL）に変わるため、
  physical_ai_exam のデータ生成・評価を動かすシェルでは読み込まない（描画が変わると学習データと見た目が変わる）。
- 配布ファイルをダウンロードできないときは、同じ版のファイル（`NVIDIA-Linux-x86_64-<版>.run`）を取得して
  `NV_RUN_FILE=<ファイルのパス> bash scripts/setup_vulkan_sagemaker.sh` のように指定する。
