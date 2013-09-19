#!/usr/bin/ruby

=begin
# This script scrapes the links from your Humble Indie Bundle account page
# (which you have to download and save by yourself) and outputs a shell script
# that
# (1) prepares a directory structure to store all the files
# (2) sends the appropriate commands to transmission-remote to get the files
#     that can be get via BT
# (3) wgets the other files
=end

require 'nokogiri'
require 'set'

list = ARGV.first

if not list or list.empty?
	puts "Please specify a file"
end

doc = Nokogiri::HTML(open(ARGV.first))

dirs = Set.new
torrents = Hash.new do |h, k| h[k] = Array.new end
wgets = Hash.new do |h, k| h[k] = Array.new end


# the HIB page keeps each entry in a div with class 'row'
# plus a name based on the game name. We take that class
# as the root of our downloads, up to (and excluding)
# the first underscore
# The only exception is the white birch
doc.css('div.row').each do |div|
	name = div['class'].sub(/\s*row\s*/,'')
	case name
	when /_prototype$/
		root = name.sub(/_prototype$/,'').gsub('_','-')
	when /^anomaly/
		root = File.join('anomaly', name[/[^_]*/].sub(/^anomaly/,''))
	else
		root = name[/[^_]*/]
	end
	# puts name, root
	div.css('.downloads').each do |dd|
		type = dd['class'].gsub(/\s*(downloads|show)\s*/,'')
		dd.css('.download').each do |dl|
			aa = dl.css('a.a').first
			link = aa['href']
			btlink = aa['data-bt']
			bt = btlink && !btlink.empty?
			md5 = dl.css('a.dlmd5').first['href'].sub(/^#/,'') rescue "(unknown)"
			ts = dl.css('a.dldate').first['data-timestamp'] rescue "(unknown)"
			dl = true
			# puts "%s: %s MD5 %s, timestamp %s" % [type, link, md5, ts]
			if bt
				# puts "\tBT %s" % [btlink]
			end

			savepath = File.join(root, type)

			if link[-1] == '/'
				STDERR.puts "# No automatic downloads for #{savepath}, go to #{link}"
				dl = false
			end

			dirs << savepath
			if dl
				if bt
					torrents[savepath] << btlink
				else
					fname = File.basename(link).sub(/\?key=.*/,'')
					wgets[savepath] << {:fname => fname, :md5 => md5, :link => link}
				end
			end
		end
	end
end

puts '#!/bin/sh'
puts 'CURDIR="$(pwd)"'

puts <<TORFUNC

add_torrents() {
	dir="$1"
	transmission-remote -w "$dir"
	shift
	for tor in "$@" ; do
		out="$dir/$(basename "$tor" .torrent)"
		if [ -e "$out" ] ; then
			echo "$out exists, skipping"
		else
			echo "getting '$out' from '$tor'"
			transmission-remote -a $tor
		fi
	done
}

TORFUNC

puts <<GET

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

GET

puts "echo 'Making directories'"
dirs.chunk do |el|
	el.split('/').first
end.each do |el, ar|
	puts "mkdir -p '" + ar.join("' '") + "' &&"
end

lastbase = ''
puts "\necho 'Setting up torrents'"
torrents.keys.each do |dir|
	base = dir.split('/').first
	if base != lastbase
		lastbase = base
		puts "echo '    #{base}'"
	end
	fulldir = File.absolute_path(dir)
	puts "add_torrents '#{fulldir}' \\"
	puts torrents[dir].map { |tor|
		"\t'#{tor}'"
	}.join(" \\\n")
end

puts "\nexit\necho 'Manual downloads'"
wgets.keys.each do |dir|
	puts "{\ncd #{dir} &&"
	wgets[dir].each do |f|
		puts "add_wget '#{f[:md5]}' '#{f[:link]}' '#{f[:fname]}' &&"
	end
	puts "cd \"$CURDIR\"\n} &&"
end

puts "true"
