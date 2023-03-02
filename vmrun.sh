#!/usr/bin/sh

set -eu

IMAGE=
ISO=
SIZE=24G
MEMORY=2048
UEFI=0
TPM=0
VIDEO=0

help() {
    echo "Launch or install a virtual machine"
    echo "usage: $(basename "$0") '[-[hliut]] [-f iso] [-s size]' '[image]'" 1>&2
    echo "  -h, --help:   Help" 1>&2
    echo "  -i, --isos:   List downloaded ISOs" 1>&2
    echo "  -l, --images: List created images" 1>&2
    echo "  -f, --from:   Create the image from this ISO" 1>&2
    echo "  -s, --size:   Size of the new image ($SIZE)" 1>&2
    echo "  -m, --memory: Memory size of the VM ($MEMORY)" 1>&2
    echo "  -u, --uefi:   Enable UEFI via ovmf (OVMF)" 1>&2
    echo "  -t, --tpm:    Enable TPM2 via swtpm (SWTPM)" 1>&2
    echo "  -v, --video:  Enable SDL video (disabled if running an image)" 1>&2
    echo "  -d, --debug:  Trace the script execution" 1>&2
    echo "  image:        Image name to create or launch" 1>&2
}

list_isos() {
    ls -1 isos
}

list_images() {
    ls -1 images
}

find_free_port() {
    port="$1"
    while lsof -i -P -n | grep -q ":$port"; do
	port=$((port + 1))
    done
    echo "$port"
}


mkdir -p isos
mkdir -p images
mkdir -p others

while [ $# -gt 0 ]; do
    # shellcheck disable=SC2221,SC2222
    case $1 in
	-h|--help)
	    help
	    shift
	    exit 0
	    ;;
	-i|--isos)
	    list_isos
	    shift
	    exit 0
	    ;;
	-l|--list)
	    list_images
	    shift
	    exit 0
	    ;;
	-f|--from)
	    ISO="isos/$2"
	    VIDEO=1
	    shift
	    shift
	    ;;
	-s|--size)
	    SIZE="$2"
	    shift
	    shift
	    ;;
	-m|--memory)
	    MEMORY="$2"
	    shift
	    shift
	    ;;
	-u|--uefi)
	    UEFI=1
	    shift
	    ;;
	-t|--tpm)
	    UEFI=1
	    TPM=1
	    shift
	    ;;
	-v|--video)
	    VIDEO=1
	    shift
	    ;;
	-d|--debug)
	    set -x
	    shift
	    ;;
	-*|--*)
	    echo "ERROR: Unknown option $1. Use -h for help." 1>&2
	    shift
	    exit 1
	    ;;
	*)
	    IMAGE="images/$1"
	    shift
	    ;;
    esac
done

if [ -z "$IMAGE" ]; then
    echo "ERROR: Missing image parameter" 1>&2
    exit 1
fi

if [ -n "$ISO" ] && [ ! -f "$ISO" ]; then
    echo "ERROR: ISO image not found. Use -i to list all ISO available" 1>&2
    exit 1
fi

if [ ! -f "$IMAGE" ] && [ -z "$ISO" ]; then
    echo "ERROR: Image is not present. Create a new one with -f to indicate an ISO" 1>&2
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    qemu-img create -f qcow2 "$IMAGE" "$SIZE"
fi

if [ $TPM -eq 1 ]; then
    UEFI=1
    if ! type swtpm > /dev/null 2>&1; then
	SWTPM=${SWTPM:-"./bin/swtpm"}
	if [ ! -f "$SWTPM" ]; then
	   echo "ERROR: swtpm not found, install it or use SWTPM var"
	   exit 1
	fi
    else
	SWTPM="swtpm"
    fi

    TPM_DIR="others/$(basename "$IMAGE")/tpm"
    TPM_SOCK="$TPM_DIR/swtpm-sock"
    mkdir -p "$TPM_DIR"
    $SWTPM socket \
	   --terminate \
	   --tpmstate dir="$TPM_DIR" \
	   --ctrl type=unixio,path="$TPM_SOCK" \
	   --tpm2 &
fi

if [ $UEFI -eq 1 ]; then
    if [ ! -f "/usr/share/qemu/ovmf-x86_64-code.bin" ]; then
	OVMF=${OVMF:-"/usr/share/qemu/ovmf-x86_64-code.bin"}
	if [ ! -f "$OVMF" ]; then
	    echo "ERROR: ovmf not found, install it or use OVMF var"
	    exit 1
	fi
    else
	OVMF="/usr/share/qemu/ovmf-x86_64-code.bin"
    fi

    OVMF_VARS="others/$(basename "$IMAGE")/ovmf-x86_64-vars.bin"
    if [ ! -f "$OVMF_VARS" ]; then
	mkdir -p "others/$(basename "$IMAGE")"
	cp /usr/share/qemu/ovmf-x86_64-vars.bin "$OVMF_VARS"
    fi
fi

CDROM=
if [ -n "$ISO" ]; then
    CDROM="-cdrom $ISO"
fi

DRIVES=
if [ $UEFI -eq 1 ]; then
    DRIVES="-drive if=pflash,format=raw,unit=0,readonly=on,file=$OVMF"
    DRIVES="$DRIVES -drive if=pflash,format=raw,unit=1,file=$OVMF_VARS"
fi

CHARDEV=
if [ $TPM -eq 1 ]; then
    CHARDEV="-chardev socket,id=chrtpm,path=$TPM_SOCK"
    CHARDEV="$CHARDEV -tpmdev emulator,id=tpm0,chardev=chrtpm"
    CHARDEV="$CHARDEV -device tpm-tis,tpmdev=tpm0"
fi

DISPLAY=
if [ $VIDEO -eq 0 ]; then
    DISPLAY="-display none"
fi

PORT=$(find_free_port 10022)

ssh-keygen -R "[localhost]:10022" -f "$HOME/.ssh/known_hosts" > /dev/null 2>&1

echo "echo \"PermitRootLogin yes\" > /etc/ssh/sshd_config.d/root.conf"
echo "systemctl restart sshd.service"
echo "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p $PORT root@localhost"

# TODO - Multiple VMs at the same time
# TODO - No graphic output option
# TODO - Detect firewall that stop mcast
# TODO - Add overlay / template images
# TODO - How to do the initial configuration on the VM
# TODO - Support local network (mcast, dnsmasq)
# TODO - Write it in Rust before it gets too big
# TODO - Use spice / VNC
# Some recommendations from https://wiki.gentoo.org/wiki/QEMU/Options

# shellcheck disable=SC2086
qemu-system-x86_64 \
    -machine type=q35,accel=kvm \
    -cpu host \
    -m "$MEMORY" \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd="tcp::$PORT-:22" \
    -device virtio-net-pci,netdev=net1 \
    -netdev socket,id=net1,mcast=230.0.0.1:1234 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-pci,rng=rng0 \
    $DRIVES \
    $CHARDEV \
    $CDROM \
    $DISPLAY \
    -drive file="$IMAGE",if=virtio
