#!/usr/bin/ruby

=begin
# This script retrieves the links to the Humble Bundle products you have bought
# and outputs a shell script that
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
require 'yaml'
require 'json'

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

# directories to be created
$dirs = Set.new

# torrents to be downloaded
$torrents = Hash.new do |h, k| h[k] = Array.new end

# files to be downloaded directly
$wgets = Hash.new do |h, k| h[k] = Array.new end

# symbolink links between files with multiple categorizations
$links = Hash.new do |h, k| h[k] = Array.new end

# Mark a game for download (torrent if possible, otherwise direct)
def mark_download game
	if game.btlink
		$torrents[game.path] << game
	else
		$wgets[game.path] << game
	end
end

# Mark a game for symlink
def mark_link game, ref
	$links[ref] << game
end

# 'root' of a name, removing information such as
# 'bundle', 'prototype', etc. Based off the used (class) name
# up to (and excluding) the first underscore
def get_root name
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
	when /withsoundtrack$/
		root = root.sub(/withsoundtrack$/,'').gsub('_','-')
	else
		root = root[/[^_]*/]
	end
	return root
end

# Process an old-style (pre-API) HTML file
def process_oldstyle_html contents
	doc = Nokogiri::HTML(contents)

	# the HIB page keeps each entry in a div with class 'row'
	# plus a name based on the game name.
	doc.css('div.row').each do |div|
		name = div['class'].sub(/\s*row\s*/,'')
		root = get_root name
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
					fname = File.basename(link).sub(/\?(key|ttl)=.*/,'')
					fkey = fname.intern
					$files[fkey] << Game.new(fname, md5, savepath, link, btlink)#, ts)
				end
			end
		end
	end
end

# File where settings are stored
SETTINGS = 'settings.yml'

# File where cookies are stored
COOKIES = 'cookies.json'
# cookies!
$cookies = {}

# Store cookies based on the set-cookie headers in a response
def set_cookies resp
	resp.get_fields('set-cookie').each do |cookie|
		set = cookie.split('; ', 2).first.split('=')
		if set.length == 1
			$cookies.delete(set.first)
		else
			$cookies[set.first]=set.last
		end
	end
end

# Return the cookies in a header-compatible format
def get_cookies
	return $cookies.map { |k,v| "#{k}=#{v}"}.join('; ')
end

# Download the user home page on Humble Bundle
def download_home username, password
	STDERR.puts "Downloading HIB home ..."
	url = URI.parse('https://www.humblebundle.com/login')
	http = Net::HTTP.new(url.host, url.port)
	http.use_ssl = true
	resp, data = http.get(url.path)
	set_cookies resp
	data = "goto=/home&username="+username+"&password="+password+"&authy-token&submit-data="
	headers = {
		'Cookie' => get_cookies,
		'Referer' => url.to_s,
		'Content-Type' => 'application/x-www-form-urlencoded'
	}
	resp, data = http.post(url.path, data, headers)
	set_cookies resp
	res = http.get(resp.response['Location'], {'Cookie:' => get_cookies})
	return res.body
end

# Issue an API call
API_URL = 'https://www.humblebundle.com/api/v1/'
def api_call path
	url = URI.parse API_URL+path
	http = Net::HTTP.new(url.host, url.port)
	http.use_ssl = true
	resp = http.get(url.path, {'Cookie:' => get_cookies})
	return resp.body
end

# Download the JSON data for the given game keys
def process_gamekeys gks, json
	data = {}
	gks.each do |key|
		STDERR.puts "Getting data for order #{key}"
		data[key] = JSON.parse(api_call "order/#{key}")
	end
	File.write json, JSON.dump(data)
	return data
end

# Parse the JSON data and build the Game list
def process_json_data jd
	jd.each do |gk, hash|
		hash['subproducts'].each do |prod|
			root = get_root prod['machine_name']
			prod['downloads'].each do |dd|
				type = dd['platform']
				savepath = File.join(root, type)
				$dirs << savepath
				dd['download_struct'].each do |ds|
					sha1 = ds['sha1']
					md5 = ds['md5']
					ts = ds['timestamp']
					if ds['url']
						link = ds['url']['web']
						btlink = ds['url']['bittorrent']
						btlink = nil if btlink and btlink.empty?
						dl = true
					elsif (link = ds['external_link'])
						# TODO only announce once per external link
						STDERR.puts "# No automatic downloads for #{savepath}, go to #{link}"
						dl = false
					end
					if dl
						fname = File.basename(link).sub(/\?(key|ttl)=.*/,'')
						fkey = fname.intern
						# TODO use sha1
						$files[fkey] << Game.new(fname, md5, savepath, link, btlink)#, ts)
					end
				end
			end
		end
	end
end

## Main action from here on

options = {}

optparse = OptionParser.new do |opts|
	opts.banner = "Usage: grab-hib.rb [options]"
	opts.on("-d", "--download FILENAME", "download library index into FILENAME.html, FILENAME.json") do |download|
		options[:download] = download
	end
	opts.on("-h", "--help", "Display this screen") do
		puts opts
		exit
	end
end

# Load settings and (potentially old)
settings = YAML.load_file SETTINGS
File.open(COOKIES) { |f| $cookies.replace JSON.load f} if File.exists? COOKIES

optparse.parse!

if not options[:download]
	html = ARGV.first
	if not html or html.empty?
		puts "Please specify a file"
		exit
	end
	json = html.sub(/(.html?)?$/,'.json')
	contents = File.read html
else
	html = options[:download] + '.html'
	json = options[:download] + '.json'
	contents = download_home(settings['username'], settings['password'])
	File.write html, contents
	File.write COOKIES, JSON.dump($cookies)
end

# `contents` holds the file contents of either the file passed on the command line
# or the library index page downloaded from the Internet. We need to determine if it's
# an old (pre-API) index file, a new (API) index file, or the JSON file with the list of
# all products already

gk = contents.match /gamekeys: (\[[^\]]+\])/
if gk
	# API index files have a gamekeys list, use it to build a JSON of the
	# product data (and store it on disk too, for future uses)
	gks = JSON.parse gk[1]
	STDERR.puts "API-based index file, game keys #{gks.join(', ')}"
	json_data = process_gamekeys gks, json
elsif contents[0,1] == '{'
	STDERR.puts "JSON product data"
	# If the contents start with a '{' we assume it's a (previously stored by us)
	# JSON list of product data, so parse it
	json_data = JSON.parse contents
else
	# In all other cases, assume an old (pre-API) index file
	STDERR.puts "Pre-API index file"
	json_data = nil
end

# Build the Game lists
if json_data
	# show the products we are dealing with, sorted by (natural) machine name
	prodlist = json_data.map do |k, v|
		v['product']
	end.sort do |p1, p2|
		pm1 = p1['machine_name'].scan(/^(\w+)(\d+)?$/).first
		pm2 = p2['machine_name'].scan(/^(\w+)(\d+)?$/).first
		pm1[1] = pm1[1].to_i
		pm2[1] = pm2[1].to_i
		pm1 <=> pm2
	end.map do |p|
		#"%s (%s)" % [p['human_name'], p['machine_name']]
		p['human_name']
	end
	STDERR.puts "Products: #{prodlist.join(', ')}"
	process_json_data json_data
else
	process_oldstyle_html contents
end


puts '#!/bin/sh'
puts 'CURDIR="$(pwd)"'
puts '. ./hib-utils.sh'

puts "echo 'Making directories'"
$dirs.sort.chunk do |el|
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
