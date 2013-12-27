#!/bin/sh

add_torrents() {
	dir="$1"
	transmission-remote -w "$dir"
	shift
	for tor in "$@" ; do
		eval "$tor"
		out="$dir/$out"
		if [ -e "$out" ] ; then
			echo "$out exists, skipping"
		elif [ -e "$out.part" ] ; then
			echo "$out.part exists, skipping $out"
		else
			echo "getting '$out' from '$tor'"
			transmission-remote -a $tor
		fi
	done
}

add_wget() {
	md5="$1"
	link="$2"
	fname="$3"
	if [ -e "$fname" ] ; then
		if ( echo "$md5 $fname" | md5sum --status -c - ) ; then
			echo "$fname exists and is OK, skipping"
		else
			echo "$fname exists, MD5 fail, regetting"
			rm "$fname"
			wget -O "$fname" "$link"
		fi
	else
		echo "getting $fname from $link"
		wget -O "$fname" "$link"
	fi
}

