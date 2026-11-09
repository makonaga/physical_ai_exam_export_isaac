# Isaac on AWS - Isaac の導入ガイド

このドキュメントでは、Isaac EC2 に Isaac Sim 5.1・Isaac Lab 2.3.0・LeIsaac を導入する手順を説明します。
組み合わせは LeIsaac の公式手順（Isaac Sim 5.1 / Isaac Lab v2.3.0 / Python 3.11 / CUDA 12.8 / PyTorch 2.7.0）に合わせています。

> **状態**: ステップ1〜7（Isaac Lab のインストールまで）は検証済みです。
> ステップ8以降（Isaac Sim の起動確認、LeIsaac 本体、ロボットとシーンのファイル）は未実施です。

## 前提条件

- [05_sagemaker_studio_setup.md](./05_sagemaker_studio_setup.md) まで完了し、Studio のターミナルから EC2 に SSH できること

以下は**特に断りがなければ EC2 の中**で実行します。

---

## ステップ1: EC2 にログインして状態を確認する

SageMaker Studio の JupyterLab のターミナルから、EC2 にログインします。

```bash
ssh -i ~/.ssh/isaac-key.pem ubuntu@<EC2のプライベートIP>
```

ログイン時の表示（検証時）で、AMI のドライバと CUDA の版を確認できます。

```
AMI Name: Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)
NVIDIA driver version: 595.112.07
CUDA versions available: cuda-12.8 cuda-12.9 cuda-13.0 cuda-13.2
```

ディスクの空き容量と、使うツールがあるかを確認します。

```bash
df -h / && for c in conda tmux git; do printf '%s: ' $c; command -v $c || echo "なし"; done
```

検証時は、空き 146GB（200GB 中 49GB 使用）、tmux と git はあり、conda はなしでした。

---

## ステップ2: tmux の起動

インストールには時間がかかるので、SSH が切れても作業が止まらないよう tmux の中で行います。

```bash
tmux new -s isaac
```

SSH が切れた場合は、もう一度ログインしてから `tmux attach -t isaac` で元の画面に戻れます。

---

## ステップ3: conda（Miniforge）のインストール

```bash
cd ~ && wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh && bash Miniforge3-Linux-x86_64.sh -b -p $HOME/miniforge3 && rm Miniforge3-Linux-x86_64.sh && $HOME/miniforge3/bin/conda init bash && source ~/.bashrc && conda --version
```

検証時は `conda 26.9.4` でした。

---

## ステップ4: Python 環境（Python 3.11・CUDA 12.8・PyTorch 2.7.0）

```bash
conda create -y -n leisaac python=3.11 && conda activate leisaac && conda install -y -c "nvidia/label/cuda-12.8.1" cuda-toolkit && pip install -U torch==2.7.0 torchvision==0.22.0 --index-url https://download.pytorch.org/whl/cu128 && python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

検証時の出力:

```
2.7.0+cu128 True NVIDIA L40S
```

---

## ステップ5: Isaac Sim 5.1 のインストール

10 分以上かかることがあります。

```bash
pip install --upgrade pip && pip install "isaacsim[all,extscache]==5.1.0" --extra-index-url https://pypi.nvidia.com
```

最後に `ERROR: ... wheel 0.48.0 requires packaging>=24.0, but you have packaging 23.0` と表示されますが、
Isaac Sim が `packaging` を 23.0 に固定しているためです。`wheel` はパッケージの作成にだけ使うもので、動作には影響しません。

Isaac Sim の使用許諾（EULA）に同意する設定をします（ないと初回起動時に同意を求められて止まります）。

```bash
echo 'export OMNI_KIT_ACCEPT_EULA=YES' >> ~/.bashrc && export OMNI_KIT_ACCEPT_EULA=YES && pip show isaacsim | sed -n 1,2p
```

`Version: 5.1.0.0` と表示されれば OK です。

---

## ステップ6: LeIsaac の取得と Isaac Lab のインストール

LeIsaac のリポジトリには、対応する Isaac Lab（v2.3.0、Isaac Sim 5.1 用）がサブモジュールとして含まれています。

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq cmake build-essential && cd ~ && git clone --recursive https://github.com/LightwheelAI/leisaac.git && cd ~/leisaac/dependencies/IsaacLab && cat VERSION && ./isaaclab.sh --install
```

`cat VERSION` で `2.3.0` と表示されます。インストールは 10 分ほどかかります。

**既知の問題**: このままだと Isaac Lab の本体（`isaaclab`）だけが入りません（`isaaclab_assets`・`isaaclab_mimic`・`isaaclab_rl`・
`isaaclab_tasks` は入ります）。本体が使う `flatdict==4.0.1` を pip が組み立てる（ビルドする）ときに最新の `setuptools` を使いますが、
最新版では `pkg_resources` が削除されているため、`ModuleNotFoundError: No module named 'pkg_resources'` で失敗します。
次のステップ7で直します。

---

## ステップ7: Isaac Lab 本体の補修と、パッケージの版合わせ

`flatdict` を古い `setuptools`（80 未満）で組み立ててから、Isaac Lab の本体を入れ直します。

```bash
cd ~/leisaac/dependencies/IsaacLab && pip install "setuptools<80" && pip install --no-build-isolation flatdict==4.0.1 && python -m pip install --editable source/isaaclab 2>&1 | tail -n 3
```

`Successfully installed ... isaaclab-0.47.2 ...` と表示されれば OK です。

このとき `packaging` が 26.3 に上がるので、Isaac Sim が指定する 23.0 に戻します。
あわせて、Isaac Sim が指定する `torchaudio==2.7.0` を入れます（Isaac Lab のインストールの途中で外れるため）。

```bash
pip install "packaging==23.0" && pip install torchaudio==2.7.0 --index-url https://download.pytorch.org/whl/cu128 && pip list 2>/dev/null | grep -iE "^isaaclab |^packaging|^torch|^warp"
```

検証時の出力:

```
isaaclab                                 0.47.2             /home/ubuntu/leisaac/dependencies/IsaacLab/source/isaaclab
packaging                                23.0
torch                                    2.7.0+cu128
torchaudio                               2.7.0+cu128
torchvision                              0.22.0+cu128
warp-lang                                1.19.0
```

### 残っている警告（動作に影響しないもの）

| 警告 | 理由 |
|------|------|
| `tensordict` / `stable-baselines3` が新しい PyTorch（2.8 以上・2.11 以上）を要求 | 強化学習用のライブラリ。データ生成・評価では使わない |
| `wheel` / `pytest` が `packaging>=24` を要求 | パッケージの作成・テスト用の道具。動作には使わない |

### 注意: warp-lang の版

Isaac Lab 2.3.0 は `warp-lang` の版を指定していないため、最新の 1.19.0 が入ります。
Isaac Lab 2.3.0 の公開（2025 年 10 月）より新しいので、ステップ8の起動確認でエラーが出た場合は、当時の版に下げることを検討します。

---

## ステップ8以降（未実施）

1. Isaac Sim の起動確認（`./isaaclab.sh -p scripts/tutorials/00_sim/create_empty.py --headless`）
2. LeIsaac 本体のインストール（`pip install -e "source/leisaac[lerobot]"`）
3. ロボットとシーンのファイルの取得
4. LeIsaac の自動データ生成で、LeRobot 形式のデータができるかの確認

---

## 次のステップ

作業を終えるときは [07_ami_operation.md](./07_ami_operation.md) の手順で AMI に保存し、EC2 を削除します。
