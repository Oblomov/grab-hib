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
	puts "transmission-remote -w '#{fulldir}' &&"
	torrents[dir].each do |tor|
		puts "transmission-remote -a '#{tor}' &&"
	end
end

puts "\necho 'Manual downloads'"
wgets.keys.each do |dir|
	puts "{\ncd #{dir} && touch md5 &&"
	wgets[dir].each do |f|
		puts "echo '#{f[:md5]} #{f[:fname]}' >> md5 &&"
		puts "wget -c '#{f[:link]}' -O '#{f[:fname]}' &&"
	end
	puts "md5sum -c md5 &&"
	puts "cd \"$CURDIR\"\n} &&"
end

puts "true"
