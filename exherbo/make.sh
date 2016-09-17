#!/bin/sh
#
# exherbo/make.sh - prepares an exherbo stage for docker usage
#
# Copyright (c) 2016 Kylie McClain <kylie@somasis.com>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e

edo() {
    printf '+ %s\n' "$*" >&2
    "$@"
}

export PALUDIS_DO_NOTHING_SANDBOXY=1

TMPDIR=${TMPDIR:-/tmp}

tar="${1:-http://dev.exherbo.org/stages/exherbo-amd64-current.tar.xz}"
sha1="${2:-http://dev.exherbo.org/stages/sha1sum}"
CHOST="${3:-x86_64-pc-linux-gnu}"

tag="${4}"
[ "${tag}" = 'date' ] && tag=
if [ -z "${tag}" ];then
    tag=$(curl -LsI "${tar}" | grep Last-Modified | cut -d' ' -f2-)
    tag=$(date -d "${tag}" -D "%a, %d %b %Y %H:%M:%S GMT" +%Y-%m-%d)
else
    if echo "${tag}" | grep -Eq '^[0-9]{4,}-[0-9]{2}-[0-9]{2}$';then
        printf 'error: %s\n' "${tag} is not a valid tag; %Y-%m-%d or 'date'" >&2
        exit 3
    fi
fi

printf 'making somasis/exherbo-%s:%s...\n\n' "${CHOST}" "${tag}"

proc=$(nproc 2>/dev/null || echo $(( $(grep -c processor /proc/cpuinfo) * 2 )))

tmp="${5}"
[ -d "${tmp}" ] || tmp=$(mktemp -d)
edo cd "${tmp}"
for url in "${tar}" "${sha1}";do
    [ -f "${url##*/}" ] || edo curl -#LO "${url}"
done
grep "${tar##*/}" "${sha1##*/}" | sha1sum -c

if [ ! -d chroot ];then
    edo mkdir chroot
    edo tar -C chroot -xpf "${tmp}"/"${tar##*/}"
fi

for d in dev dev/pts proc sys;do
    mountpoint -q chroot/"${d}" || edo mount --bind /"${d}" chroot/"${d}"
done

edo printf 'nameserver %s\n' 8.8.8.8 8.8.4.4 > chroot/etc/resolv.conf

# given the lack of need for an init system we can save time by just using eudev
edo printf '%s\n' \
    '*/* build_options: jobs=1 -recommended_tests symbols=strip work=remove' \
    "*/* targets: ${CHOST}" \
    "*/* providers: -* busybox pkgconf eudev elinks openssl libelf libxml2" \
    '*/* python_abis: -* 2.7' \
    '*/* parts: -documentation' \
    '*/* bootstrap -bash-completion -ncurses -systemd -truetype -vim-syntax -X' \
    'dev-libs/libxml2 python' \
    "*/* build_options: jobs=${proc}" \
    > chroot/etc/paludis/options.conf
case "${CHOST}" in
    *-gnu)
        edo printf '%s\n' "virtual/awk providers: -busybox gnu" >> chroot/etc/paludis/options.conf
    ;;
esac

edo printf '%s\n' \
    "PALUDIS_DO_NOTHING_SANDBOXY=1" \
    "CAVE_RESOLVE_OPTIONS='-J 0 --suggestions display --recommendations display'" \
    "CAVE_SYNC_OPTIONS='--sequential'" \
    > chroot/etc/env.d/99somasis-docker
edo chroot ./chroot eclectic env update

if [ -d chroot/var/db/paludis/repositories/cross-installed ];then
    for cross in chroot/var/db/paludis/repositories/cross-installed/*;do
        cross=${cross##*/}
        edo chroot ./chroot cave uninstall -mx -4 "${cross}" -u system -u '*/*::installed' \
            -x $(chroot ./chroot cave print-ids -m "*/*::${cross}" --format "%c/%p:%s::${cross}\n")
        edo rm -rf chroot/usr/${cross}
        edo rm -rf chroot/var/db/paludis/repositories/cross-installed/${cross}
        edo rm -rf chroot/etc/paludis/repositories/${cross}.conf
    done
    edo rmdir chroot/var/db/paludis/repositories/cross-installed
fi

for r in chroot/etc/paludis/repositories/*.conf;do
    r=${r##*/}
    r=${r%.conf}
    if grep -q 'git+https://git.exherbo.org' chroot/etc/paludis/repositories/${r}.conf;then
        edo sed -e 's|git.https://git.exherbo.org|git://git.exherbo.org|' -i chroot/etc/paludis/repositories/${r}.conf
        edo printf '%s\n' "sync_options = --git-clone-option=--depth=1 --git-pull-option=--depth=1 --git-fetch-option=--depth=1" >> chroot/etc/paludis/repositories/${r}.conf
    fi
    if [ -d "chroot/var/db/paludis/repositories/${r}/.git" ];then
        edo git clone --depth=1 chroot/var/db/paludis/repositories/${r} chroot/var/db/paludis/repositories/${r}-shallow
        edo rm -rf chroot/var/db/paludis/repositories/${r}
        edo mv chroot/var/db/paludis/repositories/${r}-shallow chroot/var/db/paludis/repositories/${r}
    fi
done

edo printf '%s\n' "sync_options = --git-clone-option=--depth=1 --git-pull-option=--depth=1 --git-fetch-option=--depth=1" >> chroot/etc/paludis/repository.template

edo chroot ./chroot cave sync --sequential
edo chroot ./chroot cave purge -x

edo echo "* $(grep '^arbor' chroot/var/db/paludis/repositories/arbor/metadata/mirrors.conf | tr -s '[[:space:]]' | cut -d' ' -f2-)" > chroot/etc/paludis/mirrors.conf

if chroot ./chroot cave print-ids -m 'dev-libs/glib-networking::installed[ssl]';then
    edo printf '%s\n' 'dev-libs/glib-networking -ssl' >> chroot/etc/paludis/options.conf
    edo chroot ./chroot cave resolve -zx1 glib-networking
fi

if chroot ./chroot cave print-ids -m 'dev-lang/perl:5.22::installed' | grep -e 'perl:5.22';then
    edo chroot ./chroot cave resolve -zx1 -u system -D perl:5.22 perl:5.24 \!perl:5.22
    edo chroot ./chroot cave resolve -zx1 -u system $(for f in arch pure;do chroot ./chroot cave print-owners -f '%c/%p:%s ' /usr/${CHOST}/lib/perl5/vendor_perl/5.22-${f};done)
fi

case "${CHOST}" in
    *-gnu*)
        p=$(chroot ./chroot cave print-ids -m '*/*::installed')
        echo "$p" | grep -q systemd && systemd=systemd
        echo "$p" | grep -q dwz && dwz=dwz
        echo "$p" | grep -q elfutils && elfutils=elfutils
        if [ -n "$dwz$elfutils$systemd" ];then
            edo chroot ./chroot cave uninstall -x $dwz $systemd $elfutils -u '*/*'
            edo chroot ./chroot cave purge -x
            edo chroot ./chroot cave resolve -cx1 installed-slots
        fi
        for f in chroot/etc/env.d/alternatives/*/busybox; do
            f=${f%/*}
            f=${f##*/}
            edo chroot ./chroot eclectic "${f}" set busybox
        done
        edo chroot ./chroot cave uninstall -x sys-apps/coreutils -u gawk
    ;;
esac

edo chroot ./chroot cave resolve -cx1 installed-slots
edo chroot ./chroot cave purge -x
edo sed -e "/jobs=${proc}/d" -i chroot/etc/paludis/options.conf

yes | edo chroot ./chroot eclectic config accept-all
edo chroot ./chroot eclectic news read new
edo chroot ./chroot eclectic news purge

for d in dev/pts dev proc sys;do
    edo umount chroot/"${d}"
done

edo cd chroot
edo printf '' > var/log/paludis.log
edo rm -r var/log/paludis/*.{messages,out}
edo rm -r var/lib/{games,systemd}
edo rm -r var/cache/paludis/distfiles/*
edo rm -r etc/{binfmt,modules-load,sysctl,tmpfiles}.d
edo rm -r etc/{X11,dbus-1,dhcpcd.conf,grub.d,iproute2,lynx,machine-{id,info},man.conf,modprobe.d,kernel,systemd,vconsole.conf,vim,wgetrc,xtables}

edo tar --numeric-owner -cpf ../exherbo-${CHOST}.tar .
edo cd "${tmp}"
edo rm -r "${tmp}"/chroot
edo rm -r "${tar##*/}" "${sha1##*/}"

edo docker import -c 'CMD bash -l' exherbo-${CHOST}.tar somasis/exherbo-${CHOST}:${tag}
edo docker run somasis/exherbo-${CHOST}:${tag} sh -c "cave sync --sequential"
edo rm exherbo-${CHOST}.tar
edo rmdir "${tmp}"

edo docker push somasis/exherbo-${CHOST}:${tag}
edo docker tag somasis/exherbo-${CHOST}:${tag} somasis/exherbo-${CHOST}:latest
edo docker push somasis/exherbo-${CHOST}:latest
docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep somasis/exherbo-${CHOST})
