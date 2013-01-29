require 'fileutils'
require 'syslog'
# require 'ostruct'
require 'ztk'

require "rrdgraph/version"

module RRDGraph

  class Config
    extend(ZTK::Config)

    loop_sleep 60

    points_per_sample 1
    rrd_step 60
    rows (60 * 24).div(points_per_sample)
    realrows (rows.to_f * 1.1).to_i


    width rows
    height width.div(4)

    day_steps   (60 * 60 * 24).div(rrd_step * rows)
    week_steps  ( day_steps * 7 )
    month_steps ( day_steps * 32 )
    year_steps  ( day_steps * 365 )

    rrd_dir "/var/lib/rrdgraph"
    images_dir "/var/cache/rrdgraph"
    filename "/var/log/messages"

    vertical_label "vertical label"

    parser Proc.new { |timestamp, line| puts("timestamp:#{timestamp}, line:#{line}") }

    averages Hash[
      :day => day_steps,
      :week => week_steps,
      :month => month_steps,
      :year => year_steps
    ]

    rrds Hash.new(Array.new)

    colors Hash.new("000000")
  end

  class Daemon

    def initialize
      $my_name = File.basename($0, ".rb").upcase
      @logger = ZTK::Logger.new("#{$my_name.downcase}.log")
      @logger.info { "Instantiating #{$my_name}..." }

      @logger.debug { "Attempting to load configuration from disk..." }
      (Config.from_file(File.join(File.dirname(__FILE__), "config.rb")) rescue Errno::ENOENT)

      # dump our configuration
      @logger.debug { "========== CONFIGURATION ==========" }
      @logger.debug { Config.configuration.send(:table).to_yaml }
      @logger.debug { "========== CONFIGURATION ==========" }
    end

    def init_rrd(start)
      @logger.debug { "init_rrd called" }
      Config.rrds.each do |rrd, counters|

        begin
          @logger.debug { "========== #{rrd} ==========" }
          rrd_file = File.expand_path(File.join(Config.rrd_dir, "rrdgraph_#{rrd}.rrd"))
          # next if File.exists?(rrd_file)

          rrd_splat = Array.new
          rrd_splat << "rrdtool create"
          rrd_splat << rrd_file
          rrd_splat << "--start #{start}"
          rrd_splat << "--step #{Config.rrd_step}"

          counters.each do |counter|
            rrd_splat << "DS:#{counter.name}:ABSOLUTE:#{Config.rrd_step * 2}:0:U"
          end

          Config.averages.each do |key, value|
            rrd_splat << "RRA:AVERAGE:0.5:#{value}:#{Config.realrows}"
          end

          Config.averages.each do |key, value|
            rrd_splat << "RRA:MAX:0.5:#{value}:#{Config.realrows}"
          end

          rrd_splat.compact!
          @logger.info { rrd_splat.join("\n") }

          rrd_command = rrd_splat.join(' ')
          FileUtils.mkdir_p(File.dirname(rrd_file))
          %x( #{rrd_command} )

        rescue Exception => e
          puts("EXCEPTION: #{e.message}")
          @logger.fatal { e.inspect }
          e.backtrace.each { |line| @logger.fatal { line } }
          exit!
        end

      end

    end

    def update(type)
      if type.nil?
        @logger.debug { "UNKNOWN: #{line}" }
        return
      end
      type = type.to_sym
      @logger.debug { "UPDATE: #{@minute}: #{type}" }
      @statistics[type] += 1
      return if @minute <= @this_minute

      Config.rrds.each do |rrd, counters|
        rrd_file = File.expand_path(File.join(Config.rrd_dir, "rrdgraph_#{rrd}.rrd"))
        rrd_splat = Array.new
        rrd_splat << "rrdtool update"
        rrd_splat << rrd_file

        stats = [ "#{@this_minute}" ]
        counters.each do |counter|
          stats << @statistics[counter.name.to_sym]
        end
        rrd_splat << stats.join(":")

        rrd_splat.compact!
        @logger.debug { rrd_splat.join(" ") }

        rrd_command = rrd_splat.join(' ')
        %x( #{rrd_command} )
      end

      @this_minute = @minute
      @logger.debug { "statistics=#{@statistics.inspect}" }
      @totals.merge!(@statistics) { |k,o,n| k = (o + n) }
      @statistics = Hash.new(0)

    end

    def process_syslog_time(line)
      bits = line.split(" ")[0..2]
      hour, minute, second = bits[2].split(":")
      timestamp = Time.utc(Time.now.year, bits[0], bits[1], hour, minute, second)
      @minute = (timestamp.to_i - timestamp.to_i.modulo(Config.rrd_step))
      @this_minute ||= @minute
      @minute
    end

    def run
      @logger.info { "Running #{$my_name}..." }
      start = -(60 * 60 * 24 * 7)
      init_rrd(start)

      file_pos = 0
      file_lines = 0
      @statistics = Hash.new(0)
      @totals = Hash.new(0)

      loop do

        begin
          file_lines = IO.readlines(Config.filename)
          file_line_count = file_lines.count
          if (file_line_count < file_pos)
            @logger.info("Reset file position!")
            file_pos = 0
          end

          @logger.debug { "file_pos=#{file_pos}, file_lines=#{file_line_count}" }
          processed_lines = false
          (file_pos != (file_line_count - 1)) && file_lines[file_pos..-1].map(&:chomp).each_with_index do |file_line, index|
            file_pos += 1
            (file_pos.modulo(10000) == 0) and @logger.info { "Processed 10,000 lines of '#{Config.filename}', now at line #{file_pos} of #{file_line_count}." }
            process_syslog_time(file_line)
            type = Config.parser.call(file_line)
            type and update(type)
            processed_lines = true
          end
          processed_lines and @logger.info("Processed more lines")
          @logger.debug { "file_pos=#{file_pos}, file_lines=#{file_line_count}" }

          @logger.info { "totals=#{@totals.inspect}" }
          return

          @logger.debug { "loop_sleep=#{Config.loop_sleep}" }
          sleep(Config.loop_sleep)

        rescue Exception => e
          puts("EXCEPTION: #{e.message}")
          @logger.fatal { e.inspect }
          e.backtrace.each { |line| @logger.fatal { line } }
          exit!
        end

      end
    end

  end

  class CGI

    def initialize
      $my_name = File.basename($0, ".rb").upcase
      @logger = ZTK::Logger.new(STDOUT || "#{$my_name.downcase}.log")
      @logger.info { "Instantiating #{$my_name}..." }

      @logger.debug { "Attempting to load configuration from disk..." }
      (Config.from_file(File.join(File.dirname(__FILE__), "config.rb")) rescue Errno::ENOENT)

      @logger.debug { "========== CONFIGURATION ==========" }
      @logger.debug { Config.configuration.send(:table).to_yaml }
      @logger.debug { "========== CONFIGURATION ==========" }
    end

    DEFAULT_RANGE = (60 * 60 * 24 * 7)
    def graph(range=DEFAULT_RANGE)
      step = (range * Config.points_per_sample).div(Config.width)
      Config.rrds.each do |rrd, counters|
        counter_max_name_length = counters.map(&:name).map(&:length).max + 1
        rrd_file = File.expand_path(File.join(Config.rrd_dir, "rrdgraph_#{rrd}.rrd"))
        image_file = File.expand_path(File.join(Config.images_dir, "rrdgraph_#{rrd}.png"))

        rrd_splat = Array.new
        rrd_splat << "rrdtool graph"
        rrd_splat << image_file
        rrd_splat << "--imgformat PNG"
        rrd_splat << "--width #{Config.width}"
        rrd_splat << "--height #{Config.height}"
        rrd_splat << "--start #{-range}"
        rrd_splat << "--vertical-label '#{Config.vertical_label}'"
        counters.all?{ |c| c.negative != true } and (rrd_splat << "--lower-limit 0")
        rrd_splat << "--units-exponent 0"
        Config.colors.each do |key, value|
          rrd_splat << "--color #{key.upcase}##{value.upcase}"
        end
        # rrd_splat << "--lazy"

        counters.each do |counter|
          rrd_splat << "DEF:a#{counter.name}=#{rrd_file}:#{counter.name}:AVERAGE"
          rrd_splat << "DEF:m#{counter.name}=#{rrd_file}:#{counter.name}:MAX"
          rrd_splat << "CDEF:ra#{counter.name}=a#{counter.name},60,*"
          rrd_splat << "CDEF:rm#{counter.name}=m#{counter.name},60,*"

          rrd_splat << "CDEF:d#{counter.name}=a#{counter.name},UN,0,a#{counter.name},IF,#{step},*"
          rrd_splat << "CDEF:s#{counter.name}=PREV,UN,d#{counter.name},PREV,IF,d#{counter.name},+"

          if counter.negative == true
            rrd_splat << "CDEF:neg#{counter.name}=0,ra#{counter.name},-"
            rrd_splat << "#{counter.draw}:neg#{counter.name}##{counter.color}:'#{"%-10s" % counter.name.capitalize}'"
          else
            rrd_splat << "#{counter.draw}:ra#{counter.name}##{counter.color}:'#{"%-10s" % counter.name.capitalize}'"
          end

          rrd_splat << "GPRINT:s#{counter.name}:MAX:'total\\: %8.0lf msg'"
          rrd_splat << "GPRINT:ra#{counter.name}:AVERAGE:'avg\\: %5.2lf msgs/min'"
          rrd_splat << "GPRINT:rm#{counter.name}:MAX:'max\\: %4.0lf msgs/min\\l'"

          if counter.negative == true
            rrd_splat << "HRULE:0#000000"
          end
        end

        rrd_splat.compact!
        rrd_command = rrd_splat.join(' ')
        @logger.info { rrd_splat.join("\n") }

        %x( #{rrd_command} )
      end
    end

  end

end
