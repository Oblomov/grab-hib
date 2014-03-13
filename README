# Humble Bundle URL grabber

If you are like me and have bought lots and lots of Humble Bundles, you
may have grown bored of downloading each game, e-book and soundtrack
separately.

Fear no more, this script is for you. You can use it to grab your Humble
Library and set up the downloads of everything you paid for in an
orderly manner.

# Usage

`grab-hib.rb` is the main program. It's a Ruby script that parses your
Humble Library (see below for further information) and _produces a shell
script_. This shell script is the one that does the actual downloading
and related tasks.

`grab-hib.rb` can download your Humble Library HTML file by itself, or
you can do the downloading and pass it to the command line. To let
`grab-hib.rb` do the downloading, you'll have to create a `settings.yml`
file with your username/email and password for login on Humble Bundle:
just copy `settings.yml.sample` to `settings.yml` and edit the two
fields.

For automatic download, usage is:

	./grab-hib.rb -d whatever > doit

This will download all the required data about your Humble Library and
echo the instructions to download everything in an orderly directory
structures, instructions which are redirecting to the file `doit` in
this example. Running `doit` (e.g. with `sh ./doit`) will start the
actual downloads.

Data about your library is stored in a pair of files called
`whatever.html` (which can be used to re-extract the list of bundles
bought without contacting the Humble Bundle website again) and
`whatever.json` (which contains the actual list of products shipped with
the bundles). These files can be use to re-create the download script,
by issuing either:

	./grab-hib.rb whatever.html > doit

which will attempt to re-download the list of products in each bundle
you bought, or

	./grab-hib.rb whatever.json > doit

which will just re-extract the data from the already downloaded list.

# Downloads

`grab-hib.rb` will set up the product downloads to rely on BitTorrent if
possible, using the scriptable command-line remote interface for
[transmission](http://transmissionbt.com). For products that do not have
a BitTorrent source, a standard download is issued, checking existing
downloads against their reported MD5.
