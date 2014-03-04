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
require 'pathname'
require 'net/https'
require 'net/http'
require 'uri'
require 'optparse'

options = {}

optparse = OptionParser.new do |opts|
	opts.banner = "Usage: grab-hib.rb [options]"
	opts.on("-u", "--username USERNAME", "username") do |username|
		options[:username] = username
	end
	opts.on("-p", "--password PASSWORD", "password") do |password|
		options[:password] = password
	end
	opts.on("-h", "--help", "Display this screen") do
		puts opts
		exit
	end
end

begin
	optparse.parse!
	mandatory = [:username, :password]
	missing = mandatory.select{ |param| options[param].nil? }
	if not missing.empty?
		puts "Missing options: #{missing.join(', ')}"
		puts optparse
		exit
	end
rescue OptionParser::InvalidOption, OptionParser::MissingArgument
	puts $!.to_s
	puts optparse
	exit
end
Game = Struct.new(:file, :md5, :path, :weblink, :btlink)#, :timestamp)

class Game
	def <=>(other)
		self.members.each do |m|
			ret = self[m] <=> other[m]
			return ret if ret != 0
		end
		return 0
	end
end

# maps file names to an array of Game structures
$files = Hash.new do |h, k| h[k] = Set.new end

$dirs = Set.new
$torrents = Hash.new do |h, k| h[k] = Array.new end
$wgets = Hash.new do |h, k| h[k] = Array.new end
$links = Hash.new do |h, k| h[k] = Array.new end

def mark_download game
	if game.btlink
		$torrents[game.path] << game
	else
		$wgets[game.path] << game
	end
end

def mark_link game, ref
	$links[ref] << game
end

def download_home username, password
	url = URI.parse('https://www.humblebundle.com/login')
	http = Net::HTTP.new(url.host, url.port)
	http.use_ssl = true
	resp, data = http.get(url.path)
	cookie = resp.response['set-cookie'].split('; ')[0]
	data = "goto=/home&username="+username+"&password="+password+"&authy-token&submit-data="
	headers = {
		'Cookie' => cookie,
		'Referer' => url.to_s,
		'Content-Type' => 'application/x-www-form-urlencoded'
	}
	resp, data = http.post(url.path, data, headers)
	res = http.get(resp.response['Location'], {'Cookie:' => resp.response['set-cookie']})
	return res.body
end

doc = Nokogiri::HTML(download_home(options[:username],options[:password]))

# the HIB page keeps each entry in a div with class 'row'
# plus a name based on the game name. We take that class
# as the root of our downloads, up to (and excluding)
# the first underscore
# The only exception is the white birch
doc.css('div.row').each do |div|
	name = div['class'].sub(/\s*row\s*/,'')
	root = name.dup
	if root.match /^anomaly/
		root = File.join('anomaly', root[/[^_]*/].sub(/^anomaly/,''))
	end
	case root
	when /_makingof/
		root = root.sub(/_makingof.*/,'').gsub('_','-')
	when /_bundle$/
		root = root.sub(/_bundle$/,'').gsub('_','-')
	when /_prototype$/
		root = root.sub(/_prototype$/,'').gsub('_','-')
	else
		root = root[/[^_]*/]
	end
	div.css('.downloads').each do |dd|
		type = dd['class'].gsub(/\s*(downloads|show)\s*/,'')
		dd.css('.download').each do |dl|
			aa = dl.css('a.a').first
			link = aa['href']
			btlink = aa['data-bt']
			if btlink.empty?
				btlink = nil
			end
			md5 = dl.css('a.dlmd5').first['href'].sub(/^#/,'') rescue nil
			ts = dl.css('a.dldate').first['data-timestamp'] rescue nil
			savepath = File.join(root, type)

			dl = true

			if link[-1] == '/'
				STDERR.puts "# No automatic downloads for #{savepath}, go to #{link}"
				dl = false
			end

			$dirs << savepath
			if dl
				fname = File.basename(link).sub(/\?key=.*/,'')
				fkey = fname.intern
				$files[fkey] << Game.new(fname, md5, savepath, link, btlink)#, ts)
			end
		end
	end
end

puts '#!/bin/sh'
puts 'CURDIR="$(pwd)"'
puts '. ./hib-utils.sh'

puts "echo 'Making directories'"
$dirs.chunk do |el|
	el.split('/').first
end.each do |el, ar|
	puts "mkdir -p '" + ar.join("' '") + "' &&"
end

$files.each do |fkey, games|
	if games.length > 1
		md5s = games.map { |g| g.md5 }.uniq
		if md5s.length > 1 and not md5s.include? nil
			games.each { |g| mark_download g}
			next # done
		end
	end
	# We get here if there is only one game and/or the other ones can be symlinked
	ga = games.to_a.sort { |a, b| b.path <=> a.path }
	ref = ga.shift
	mark_download ref
	ga.each { |g| mark_link g, ref }
end

lastbase = ''
puts "\necho 'Setting up torrents'"
$torrents.keys.each do |dir|
	base = dir.split('/').first
	if base != lastbase
		lastbase = base
		puts "echo '    #{base}'"
	end
	fulldir = File.absolute_path(dir)
	puts "add_torrents '#{fulldir}' \\"
	puts $torrents[dir].map { |game|
		"\t\"tor='#{game.btlink}' out='#{game.file}'\""
	}.join(" \\\n")
end

puts "\necho 'Manual downloads'"
$wgets.keys.each do |dir|
	puts "{\ncd #{dir} &&"
	$wgets[dir].each do |g|
		puts "add_wget '#{g.md5}' '#{g.weblink}' '#{g.file}' &&"
	end
	puts "cd \"$CURDIR\"\n} &&"
end

puts "\necho 'Symlinking copies'"
$links.each do |ref, list|
	dst = Pathname(File.join(ref.path, ref.file))
	list.each do |g|
		src = Pathname(File.join(g.path, g.file))
		puts "# #{src} #{dst}"
		puts "test -e #{src} || ln -s #{dst.relative_path_from(src.dirname)} #{src}"
	end
end

puts "true"
