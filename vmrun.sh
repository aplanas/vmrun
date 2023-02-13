#!/usr/bin/sh

IMAGE=
ISO=
VARS=
SIZE=24G
MEMORY=1024
UEFI=0
TPM=0

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
    echo "  image:        Image name to create or launch" 1>&2
}

list_isos() {
    ls -1 isos
}

list_images() {
    ls -1 images
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
	-*|--*)
	    echo "ERROR: Unknown option $1. Use -h for help." 1>&2
	    shift
	    exit 1
	    ;;
	*)
	    IMAGE="images/$1"
	    VARS="others/$1-vars.bin"
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

    if [ ! -f "$VARS" ]; then
	cp /usr/share/qemu/ovmf-x86_64-vars.bin "$VARS"
    fi
fi

if [ $TPM -eq 1 ]; then
    if ! type swtpm > /dev/null 2>&1; then
	SWTPM=${SWTPM:-"./swtpm"}
	if [ ! -f "$SWTPM" ]; then
	   echo "ERROR: swtpm not found, install it or use SWTPM var"
	   exit 1
	fi
    else
	SWTPM="swtpm"
    fi
fi

ssh-keygen -R [localhost]:10022 -f $HOME/.ssh/known_hosts

CDROM=
if [ -n "$ISO" ]; then
    CDROM="-cdrom $ISO"
fi

DRIVES=
if [ $UEFI -eq 1 ]; then
    DRIVES="-drive if=pflash,format=raw,unit=0,readonly=on,file=$OVMF"
    DRIVES="$DRIVES -drive if=pflash,format=raw,unit=1,file=$VARS"
fi

echo "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p 10022 root@localhost"

qemu-system-x86_64 \
    -accel kvm \
    -m "$MEMORY" \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::10022-:22 \
    $DRIVES \
    $CDROM \
    -hda "$IMAGE"
