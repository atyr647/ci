# Ribbon OS gaming session defaults (sourced by ribbon-session).
# These replace common Steam launch options, so games need none.

# Big shader caches: compiled shaders are kept instead of being rebuilt,
# which removes most stutter on second launch. (NVIDIA's equivalents are in
# 20-nvidia.sh, written by ribbon-gpu.)
export MESA_SHADER_CACHE_MAX_SIZE=12G
export DXVK_STATE_CACHE_PATH="${XDG_CACHE_HOME:-$HOME/.cache}/dxvk"
export VKD3D_SHADER_CACHE_PATH="${XDG_CACHE_HOME:-$HOME/.cache}/vkd3d"

# Wine/Proton: use NTSYNC when the kernel has it (6.14+), else fsync.
if [ -e /dev/ntsync ]; then
	export WINENTSYNC=1 PROTON_USE_NTSYNC=1
fi

# HDR + native Wayland for Proton are exported by `ribbon hdr on`
# (~/.local/state/ribbon/xdg/labwc/environment.d/50-hdr.env).
