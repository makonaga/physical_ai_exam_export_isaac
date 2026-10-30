#!/usr/bin/env bash
# SageMaker Studio（JupyterLab スペース）で Vulkan を使えるようにし、GPU が見えるかを確かめる.
# Isaac Sim はカメラ画像の描画に Vulkan を使う。
#
#   bash scripts/setup_vulkan_sagemaker.sh
#
# SageMaker Studio のコンテナには、GPU ドライバのうち計算用（CUDA）のライブラリだけが渡され
# （NVIDIA_DRIVER_CAPABILITIES=compute,utility）、描画用（Vulkan / OpenGL / EGL）のライブラリは
# 渡されない。ここでは、外側のマシンのドライバと同じ版の NVIDIA ドライバ配布ファイルから
# 描画用のライブラリだけを取り出してホーム配下に置き、Vulkan で GPU が見えるかを調べる。
#
# - AWS・NVIDIA の公式な方法ではない。描画用のデバイス（/dev/dri）はコンテナの中からは作れない
#   ため、これがなくても NVIDIA の Vulkan が動くかは試すまで分からない。
# - 取り出したライブラリと設定は ~/.nvidia-gl/<ドライバの版>/ に置く（ホーム配下なので
#   スペースを再起動しても残る）。apt で入れる Vulkan のパッケージは再起動で消えるため、
#   スペースを起動するたびにこのスクリプトを実行すること（2 回目以降はダウンロードと展開を省く）。
# - 使うときは source ~/.nvidia-gl/env.sh で環境変数を設定する。今の MuJoCo のデータ生成・評価の
#   描画（CPU 描画）を変えないよう、~/.bashrc には書き込まない。
# - 配布ファイルをダウンロードできないときは、ブラウザなどで同じ版のファイルを取得して
#   NV_RUN_FILE=<ファイルのパス> bash scripts/setup_vulkan_sagemaker.sh のように指定する。
set -euo pipefail

NV_ROOT="${NV_ROOT:-$HOME/.nvidia-gl}"

# 描画用のライブラリ。NVIDIA のコンテナ用ツール（libnvidia-container / nvidia-container-toolkit）が
# 描画（graphics）を有効にしたときにコンテナへ渡すものと同じ。ドライバの版によってはないものもある
GRAPHICS_LIBS=(
    libGLX_nvidia             # OpenGL と Vulkan の本体（Vulkan のドライバを兼ねる）
    libnvidia-glcore
    libnvidia-tls
    libnvidia-glsi
    libnvidia-glvkspirv       # Vulkan のシェーダ（SPIR-V）の変換
    libnvidia-gpucomp         # シェーダのコンパイラ
    libnvidia-rtcore          # レイトレーシング（OptiX）
    libnvoptix
    libnvidia-cbl
    libnvidia-vulkan-producer
    libnvidia-allocator
    libEGL_nvidia             # EGL
    libnvidia-eglcore
    libGLESv2_nvidia
    libGLESv1_CM_nvidia
    libnvidia-fbc
    libnvidia-ifr
)

log() { printf '\n\033[1;34m[vulkan]\033[0m %s\n' "$*"; }

driver_version() {
    if [ -n "${DRIVER_VERSION:-}" ]; then
        echo "$DRIVER_VERSION"
        return
    fi
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ' || true
}

# NVIDIA の配布ファイル（.run）を ``$2`` にダウンロードする. データセンター向けと一般向けの 2 か所を順に試す
download_run() {
    local ver="$1" dest="$2"
    local name="NVIDIA-Linux-x86_64-${ver}.run"
    local url
    for url in \
        "https://us.download.nvidia.com/tesla/${ver}/${name}" \
        "https://us.download.nvidia.com/XFree86/Linux-x86_64/${ver}/${name}"; do
        echo "  $url"
        if curl -fL --retry 3 --progress-bar -o "$dest.part" "$url"; then
            mv "$dest.part" "$dest"
            return 0
        fi
    done
    rm -f "$dest.part"
    return 1
}

# 展開した配布ファイル ``$1`` から、描画用のライブラリと設定ファイルを ``$2`` に作る
install_graphics_files() {
    local src="$1" dir="$2" ver="$3"
    local lib_dir="$dir/lib"
    mkdir -p "$lib_dir"
    local lib missing=()
    for lib in "${GRAPHICS_LIBS[@]}"; do
        if [ -f "$src/$lib.so.$ver" ]; then
            cp "$src/$lib.so.$ver" "$lib_dir/"
        else
            missing+=("$lib")
        fi
    done
    if [ ! -f "$lib_dir/libGLX_nvidia.so.$ver" ]; then
        echo "配布ファイルに libGLX_nvidia.so.$ver がありません。" >&2
        return 1
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "  この版にないもの（なくてもよい）: ${missing[*]}"
    fi
    # libGLX_nvidia.so.0 などの別名（SONAME のリンク）を作る
    "$(command -v ldconfig || echo /sbin/ldconfig)" -n "$lib_dir"

    # Vulkan に NVIDIA のライブラリの場所を教えるファイル。対応する Vulkan の版は配布ファイルの
    # ひな形から読み、ライブラリは絶対パスで指定する
    local template api=""
    template="$(find "$src" -maxdepth 1 -name 'nvidia_icd.json*' | head -n1)"
    if [ -n "$template" ]; then
        api="$(sed -n 's/.*"api_version" *: *"\([^"]*\)".*/\1/p' "$template" | head -n1)"
    fi
    cat > "$dir/nvidia_icd.json" <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "$lib_dir/libGLX_nvidia.so.0",
        "api_version" : "${api:-1.3.0}"
    }
}
EOF
    # EGL に NVIDIA のライブラリの場所を教えるファイル
    cat > "$dir/10_nvidia.json" <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "$lib_dir/libEGL_nvidia.so.0"
    }
}
EOF
}

main() {
    # ------------------------------------------------------------ 1. ドライバの版
    log "1/5 GPU ドライバの版"
    local ver
    ver="$(driver_version)"
    if [ -z "$ver" ]; then
        echo "nvidia-smi で GPU ドライバの版を読めません。GPU インスタンスで実行してください。" >&2
        exit 1
    fi
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || true
    echo "  NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-（未設定）}"
    local dir="$NV_ROOT/$ver"
    local lib_dir="$dir/lib"

    # ------------------------------------------------------------ 2. 描画用ライブラリを取り出す
    if [ -f "$lib_dir/libGLX_nvidia.so.$ver" ] && [ -f "$dir/nvidia_icd.json" ]; then
        log "2/5 描画用ライブラリは取り出し済み（$dir）"
    else
        log "2/5 NVIDIA ドライバ $ver の配布ファイルから描画用ライブラリを取り出す（$dir）"
        mkdir -p "$dir"
        rm -rf "$dir"/work.*  # 前回途中で止まったときの作業ディレクトリ
        local work run
        work="$(mktemp -d "$dir/work.XXXXXX")"
        if [ -n "${NV_RUN_FILE:-}" ]; then
            run="$(realpath "$NV_RUN_FILE")"
        else
            run="$work/NVIDIA-Linux-x86_64-$ver.run"
            if ! download_run "$ver" "$run"; then
                echo "配布ファイルをダウンロードできませんでした。同じ版（$ver）のファイルを取得し、" >&2
                echo "NV_RUN_FILE=<ファイルのパス> を付けて実行し直してください。" >&2
                rm -rf "$work"
                exit 1
            fi
        fi
        # インストーラは実行せず、展開だけする（NVIDIA-Linux-x86_64-<版>/ ができる）
        (cd "$work" && TMPDIR="$work" sh "$run" --extract-only > /dev/null)
        local src
        src="$(find "$work" -maxdepth 1 -type d -name 'NVIDIA-Linux-x86_64-*' | head -n1)"
        if [ -z "$src" ]; then
            echo "配布ファイルを展開できませんでした（$run）。" >&2
            rm -rf "$work"
            exit 1
        fi
        if [ "${src##*-}" != "$ver" ]; then
            echo "配布ファイルの版（${src##*-}）がドライバの版（$ver）と違います。同じ版が必要です。" >&2
            rm -rf "$work"
            exit 1
        fi
        install_graphics_files "$src" "$dir" "$ver"
        rm -rf "$work"
    fi

    # 環境変数の設定ファイル（Isaac Sim を使うシェルで source する）
    cat > "$NV_ROOT/env.sh" <<EOF
# bash scripts/setup_vulkan_sagemaker.sh が作る（NVIDIA ドライバ $ver 用）.
# Isaac Sim を使うシェルで source する。MuJoCo の描画も GPU（EGL）に変わるので、
# 今の MuJoCo のデータ生成・評価を動かすシェルでは読み込まないこと
export LD_LIBRARY_PATH="$lib_dir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export VK_DRIVER_FILES="$dir/nvidia_icd.json"
export VK_ICD_FILENAMES="$dir/nvidia_icd.json"  # 古い Vulkan ローダー向け
export __EGL_VENDOR_LIBRARY_FILENAMES="$dir/10_nvidia.json"
EOF

    # ------------------------------------------------------------ 3. Vulkan のローダーと確認ツール
    log "3/5 Vulkan のローダーと確認ツール（libvulkan1 vulkan-tools）"
    if command -v sudo > /dev/null && sudo -n true 2> /dev/null; then
        sudo apt-get update -qq
        # Mesa の Vulkan（CPU 描画）が一緒に入らないよう、推奨パッケージは入れない
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            libvulkan1 vulkan-tools libglvnd0 > /dev/null
    else
        echo "sudo が使えないため apt のパッケージをスキップします（vulkaninfo がなければ確認できません）。"
    fi

    # ------------------------------------------------------------ 4. 依存ライブラリ
    log "4/5 取り出したライブラリが必要とするライブラリ"
    local not_found
    not_found="$(LD_LIBRARY_PATH="$lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ldd "$lib_dir"/*.so."$ver" 2> /dev/null | grep "not found" | sort -u || true)"
    if [ -n "$not_found" ]; then
        echo "  見つからないライブラリがあります:"
        echo "$not_found"
    else
        echo "  すべて見つかりました。"
    fi

    # ------------------------------------------------------------ 5. Vulkan で GPU が見えるか
    log "5/5 Vulkan で GPU が見えるか（vulkaninfo --summary）"
    echo "  GPU のデバイス: $(ls -d /dev/nvidia* /dev/dri 2> /dev/null | tr '\n' ' ' || true)"
    # shellcheck source=/dev/null
    source "$NV_ROOT/env.sh"
    local out="$dir/vulkaninfo.log"
    if ! command -v vulkaninfo > /dev/null; then
        echo "vulkaninfo がありません（3/5 を確認してください）。" >&2
        exit 2
    fi
    if vulkaninfo --summary > "$out" 2>&1 && grep -q "deviceName *= *NVIDIA" "$out"; then
        grep -E "apiVersion|driverVersion|deviceType|deviceName" "$out" | sed 's/^/  /'
        log "成功: Vulkan で NVIDIA の GPU が見えています。"
        echo "  Isaac Sim を使うシェルでは、先に次を実行してください:"
        echo "    source $NV_ROOT/env.sh"
    else
        echo "  vulkaninfo の出力（最後の 40 行。全体は $out）:"
        tail -n 40 "$out" | sed 's/^/  /'
        log "失敗: Vulkan で NVIDIA の GPU が見えませんでした。上の出力を貼ってください。"
        exit 2
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
