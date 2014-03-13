#!/usr/bin/ruby

class String
	# decode a binary-encoded string
	def bdecode
		@bdecode_idx = 0
		data = []
		#begin
			while @bdecode_idx < self.length
				data << bdecode_next
			end
#		rescue ArgumentError => e
#			STDERR.puts e
#			STDERR.puts self[0...@bdecode_idx]
#			STDERR.puts data
#			STDERR.puts self[@bdecode_idx...self.length]
#		end
		return data
	end

private

	def bdecode_next
		case self[@bdecode_idx]
		when 'd'
			bdecode_dict
		when 'i'
			bdecode_int
		when 'l'
			bdecode_list
		when /[1-9]/
			bdecode_str
		else
			raise ArgumentError, "unexpected byte at offset #{@bdecode_idx} while bdecoding string"
		end
	end

	def bdecode_dict
		hash = {}
		# sanity check
		raise ArgumentError, "not a dict at offset #{@bdecode_ix} while bdecoding string" unless self[@bdecode_idx] == 'd'
		@bdecode_idx += 1
		while (c = self[@bdecode_idx])
			# found end of dict
			if c == 'e'
				@bdecode_idx += 1
				return hash
			end
			# else, bdecode a key (always a string, make it a symbol)
			key = bdecode_str.intern
			# TODO check for dub keys?
			# next, bdecode the value
			hash[key] = bdecode_next
		end
		raise ArgumentError, "unterminated dict while bdecoding string"
	end

	def bdecode_list
		list = []
		# sanity check
		raise ArgumentError, "not a list at offset #{@bdecode_idx} while bdecoding string" unless self[@bdecode_idx] == 'l'
		@bdecode_idx += 1
		while (c = self[@bdecode_idx])
			# found end of list
			if c == 'e'
				@bdecode_idx += 1
				return list
			end
			# bdecode the next entry
			list << bdecode_next
		end
		raise ArgumentError, "unterminated list while bdecoding string"
	end

	def bdecode_int
		# sanity check
		raise ArgumentError, "not an int at offset #{@bdecode_idx} while bdecoding string" unless self[@bdecode_idx] == 'i'
		i_idx = @bdecode_idx + 1
		e_idx = self.index('e', i_idx)
		raise ArgumentError, "unterminated int while bdecoding string" unless e_idx
		@bdecode_idx = e_idx + 1
		return self[i_idx...e_idx].to_i(10)
	end

	def bdecode_str
		# find the end of the string lengt
		i_idx = self.index(':', @bdecode_idx) + 1
		raise ArgumentError, "malformed string at offset #{@bdecode_idx} while bdecoding string" unless i_idx
		len = self[@bdecode_idx...i_idx].to_i
		e_idx = i_idx + len
		@bdecode_idx = e_idx
		return self[i_idx...e_idx]
	end

end

if __FILE__ == $0
	require 'open-uri'
	require 'pp'

	ARGV.each do |fn|
		open(fn, 'rb') do |f|
			pp f.read.bdecode
		end
	end
end
