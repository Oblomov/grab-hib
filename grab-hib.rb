#!/usr/bin/ruby

=begin
# This script retrieves the links to the Humble Bundle products you have bought
# and outputs a shell script that
# (1) prepares a directory structure to store all the files
# (2) sends the appropriate commands to transmission-remote to get the files
#     that can be get via BT
# (3) wgets the other files
=end

require 'mechanize'
require 'nokogiri'
require 'set'
require 'pathname'
require 'net/https'
require 'net/http'
require 'uri'
require 'open-uri'
require 'optparse'
require 'yaml'
require 'json'
require 'date'
require 'pp'

require './bdecode'

Game = Struct.new(:file, :md5, :path, :weblink, :btlink, :bundle)#, :timestamp)

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
# should torrents be verified?
$verify = false

# files to be downloaded directly
$wgets = Hash.new do |h, k| h[k] = Array.new end

# symbolink links between files with multiple categorizations
$links = Hash.new do |h, k| h[k] = Array.new end

# Mark a game for download (torrent if possible, otherwise direct)
# We check if there is a BitTorrent link _and_ if the link works
# properly (returns a 200 OK HTTP response _and_ produces a valid
# torrent)
def mark_download game
	usebt = game.btlink ? true : false
	if usebt and $verify
		# check if it exists
		begin
			torrent = open(game.btlink).read
			begin
				decoded = torrent.bdecode.first
				fname = decoded[:info][:name]
				STDERR.puts "Torrent %s claims filename %s instead of %s" % [
					game.btlink, fname, game.file
				] if fname != game.file
			rescue => e
				STDERR.puts "Error '%s' while trying to decode %s for %s" % [
					e.message, game.btlink, game.file
				]
				usebt = false
			end
		rescue OpenURI::HTTPError => e
			STDERR.puts "%s trying to get %s for %s" % [
				e.message, game.btlink, game.file
			]
			usebt = false
		end
	end
	if usebt
		$torrents[game.path] << game
	else
		STDERR.puts "using direct download for #{game.file}" if game.btlink
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
	%w{ _[^_]*bundle
		_prototype _demo _promo _game _core
		_soundtrack(_only)? withsoundtrack _only_audio _audio _score
		_android_and_pc _android _linux _mac _windows _win _pc
		_freesong _song _remix
		_free _text _comic
		_book _ebook _coloringbook _pdf _makingof _papercraft _artbook
		_excerpt _dlc _?premium _deluxe _asm}.each do |sfx|
		root.sub!(Regexp.new(sfx), '')
	end
	root.sub!(/_((vol|issue)\d+)/, '/\1')
	[
		[ /^aaaaaa_?/, 'aaaaaa' ],
		[ /^amnesia_/, 'amnesia' ],
		[ /^anomaly/, 'anomaly' ],
		[ /^bittrip/, 'bittrip' ],
		[ /^trine2_?/, 'trine2' ],
		[ /^trine_enhanced/, 'trine' ],
		[ /^kingdomrush?/, 'kingdomrush' ], # yes, there's one with a missing h
		[ /^(the)?blackwell/, 'blackwell' ],
		[ /^ftlfasterthanlight(_ae)?/, 'ftl' ],
		[ /^talisman_?/, 'talisman' ],
		[ /^catan_?/, 'catan' ],
		[ /^shadowgrounds_?/, 'shadowgrounds' ],
		[ /^theinnerworld_?/, 'theinnerworld' ],
		[ /^peteseeger_?/, 'peteseeger' ],
		[ /^tothemoon_?/, 'tothemoon' ],
		[ /^preteniousgame_?/, 'pretentiousgame' ],
		[ /^la[-_]mulana_?/, 'lamulana' ],
	]. each do |pair|
		rx = pair.first
		base = pair.last
		root = File.join(base, root.sub(rx,'')) if rx.match root
	end
	root.gsub!('_', '-')
	return root
end

# Get a filename from a link
def get_filename link
	return File.basename(link).sub(/\?((game)?key|ttl)=.*/,'')
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
					fname = get_filename link
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
COOKIES = 'cookies.yaml'

$api_agent = Mechanize.new
$api_agent.user_agent = 'Apache-HttpClient/UNAVAILABLE (java 1.4; really grab-hib - please allow 3rd party API access officially)'

$api_agent.pre_connect_hooks << lambda do |agent, request|
	request['X-Requested-By'] = 'hb_android_app'
	request['Accept'] = 'text/json'
	request['Accept-Charset'] = 'utf-8'
end

# Show request headers to debug connections
$api_agent.pre_connect_hooks << lambda do |agent, request|
	PP.pp request.to_hash, STDERR
end if $DEBUG


if File.exist? COOKIES
	$api_agent.cookie_jar.load(COOKIES)
end

HOME_URL = 'https://www.humblebundle.com/home/library'
CAPTCHA_URL = 'https://www.humblebundle.com/user/captcha'
LOGIN_URL = 'https://www.humblebundle.com/login'

def hib_login username, password
	begin
		result = $api_agent.post(LOGIN_URL, JSON.dump({:username => username, :password => password}))
	rescue Mechanize::UnauthorizedError => e
		result = e.page
		PP.pp(result.code, STDERR) if $DEBUG
		PP.pp(result.response, STDERR) if $DEBUG
		PP.pp(result.body, STDERR) if $DEBUG
		PP.pp(JSON.parse(result.body), STDERR) if $DEBUG
		if JSON.parse(result.body)['captcha_required']
			raise NotImplementedError, "captcha required"
		else
			raise e
		end
	end
	PP.pp(result.code, STDERR) if $DEBUG
	PP.pp(result.response, STDERR) if $DEBUG
	$api_agent.cookie_jar.save_as(COOKIES) if result.code.to_i == 200
	return result
end

# Issue an API call
API_URL = 'https://www.humblebundle.com/api/v1/'
def api_call path
	resp = $api_agent.get API_URL+path
	PP.pp(resp.code, STDERR) if $DEBUG
	PP.pp(resp.response, STDERR) if $DEBUG
	return resp.body
end

def get_orders
	return api_call 'user/order'
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
			subroot = get_root prod['machine_name']
			prod['downloads'].each do |dd|
				root = subroot.dup
				# Fix KindomRush classic being put under Origin because it's included by
				# Origin Premium package
				if dd['machine_name']
					newroot = get_root dd['machine_name']
					root = newroot.dup if newroot == 'kingdomrush/'
				end
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
						STDERR.puts "# No automatic downloads for #{savepath} (#{ds['name']}), go to #{link}"
						dl = false
					end
					if dl
						fname = get_filename link
						fkey = fname.intern
						# TODO use sha1
						$files[fkey] << Game.new(fname, md5, savepath, link, btlink, [hash['product']['human_name'], gk])#, ts)
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
	opts.on("-v", "--[no-]verify", "verify torrents before selecting them") do |v|
		$verify = v
	end
	opts.on("-h", "--help", "Display this screen") do
		puts opts
		exit
	end
end

# Load settings
settings = YAML.load_file SETTINGS

$api_agent.add_auth(API_URL, settings['username'], settings['password'])

optparse.parse!

# With no option, default to download to a file name hib-YYYYMMDD
if options.empty? and ARGV.first.nil?
	options[:download] = Date.today.strftime("hib-%Y%m%d")
end

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
	login = hib_login settings['username'], settings['password']
	raise 'Failed to login/verify' if login.code.to_i != 200
	contents = get_orders
	File.write json, contents
	STDERR.puts contents.lines[0..3] if $DEBUG
end

# `contents` holds the file contents of either the file passed on the command line
# or the library index page downloaded from the Internet. We need to determine if it's
# an old (pre-API) index file, a new (API) index file, or the JSON file with the list of
# all products already

gk = contents.match(/gamekeys\s*[=:]\s*(\[[^\]]+\])/)
if gk
	# API index files have a gamekeys list, use it to build a JSON of the
	# product data (and store it on disk too, for future uses)
	gks = JSON.parse gk[1]
	STDERR.puts "API-based index file, game keys #{gks.join(', ')}"
	json_data = process_gamekeys gks, json
elsif contents[0,1] == '['
	STDERR.puts "JSON user order data"
	gks = JSON.parse(contents).map { |v| v['gamekey']}
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
		puts "echo '    #{base}' # " + $torrents[dir].map { |game|
			"%s (%s)" % game.bundle
		}.uniq.join(', ')
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
		next if src == dst
		puts "# #{src} #{dst}"
		puts "test -e #{src} || ln -s #{dst.relative_path_from(src.dirname)} #{src}"
	end
end

puts "true"
