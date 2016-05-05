#!/usr/bin/env ruby

additional_data = [
    {
        :location => "NonTox LE",
        :gigs => [
            # Fri
            { :ts => "2016-05-13 15:30", :artist => "Black Design" },
            { :ts => "2016-05-13 16:30", :artist => "Seelennacht" },
            { :ts => "2016-05-13 17:30", :artist => "Glenn Love" },
            { :ts => "2016-05-13 18:30", :artist => "INTENT:OUTTAKE" },
            { :ts => "2016-05-13 19:30", :artist => "Stoppenberg" },
            { :ts => "2016-05-13 20:30", :artist => "Centhron" },
            # Sat
            { :ts => "2016-05-14 13:30", :artist => "System Noire" },
            { :ts => "2016-05-14 14:30", :artist => "Body Harvest" },
            { :ts => "2016-05-14 15:30", :artist => "Electronic-Noise" },
            { :ts => "2016-05-14 16:30", :artist => "Rabbit at WAr" },
            { :ts => "2016-05-14 17:30", :artist => "Dark Empire" },
            { :ts => "2016-05-14 18:30", :artist => "Unterschicht" },
            { :ts => "2016-05-14 19:30", :artist => "Painbastard" },
            { :ts => "2016-05-14 20:30", :artist => "[x]-Rx" },
            # Sun
            { :ts => "2016-05-15 13:30", :artist => "Desastroes" },
            { :ts => "2016-05-15 14:30", :artist => "Profane Finality" },
            { :ts => "2016-05-15 15:30", :artist => "Neustrohm" },
            { :ts => "2016-05-15 16:30", :artist => "Lights of Euphoria" },
            { :ts => "2016-05-15 17:30", :artist => "In Good Faith" },
            { :ts => "2016-05-15 18:30", :artist => "Formalin" },
            { :ts => "2016-05-15 19:30", :artist => "Terrorfrequenz" },
            { :ts => "2016-05-15 22:30", :artist => "Rotersand" }
        ]
    }
]

require "trollop"
require "fileutils"
require "open-uri"
require "nokogiri"
require "parallel"
require "ruby-progressbar"
require "sqlite3"
require "prawn"
require "prawn/measurement_extensions"
require "pp"

# functions

class String
    def truncate(max)
        length > max ? "#{self[0...max]}..." : self
    end
end

def i18n(day)
    german = {
        "Monday"    => "Montag",
        "Tuesday"   => "Dienstag",
        "Wednesday" => "Mittwoch",
        "Thursday"  => "Donnerstag",
        "Friday"    => "Freitag",
        "Saturday"  => "Samstag",
        "Sunday"    => "Sonntag"
    }
    german[day]
end

def download(url, path)
    File.open(path, "w") do |f|
        IO.copy_stream(open(url), f)
    end
end

def error(message)
    $stderr.printf "ERROR: %s", message
end

def debug(message)
    $stderr.printf "DEBUG: %s", message if $opts[:debug]
end

def debug_endl(*args)
    ret = args.shift || nil
    if $opts[:debug]
        $stderr.print (ret ? "OKAY" : "ERROR") if !ret.nil?
        $stderr.puts
    end
end

def cond_date(min)
    sprintf "ts > '%s' and ts < '%s'",
        min.strftime("%Y-%m-%d %H:%M:%S"),
        (min + 60*60*24).strftime("%Y-%m-%d %H:%M:%S")
end

def cond_location(location)
    "location like '#{location}%'"
end

# global variables

$num_threads     = 4
$cache_base_path = "/tmp/wgt-2016"
$wgt_base_url    = "http://www.wave-gotik-treffen.de"
$wgt_bands_url   = File.join $wgt_base_url, "bands.php"

$opts = Trollop::options do
    opt :debug, "Enable debug messages."
    opt :cache, "Enable cache for downloaded data."
    opt :skip,  "Skip recreation of sqlite database."
    version "wgt-2016.rb  v0.1  © 2016 Matt <rhasqx@posteo.nz>"
end

# create cache directory

begin
    debug sprintf("create cache directory\n")
    FileUtils.mkdir_p $cache_base_path
rescue
    error sprintf("cannot create directory: %s\n", $cache_base_path)
end

# data storage

urls = Hash.new
db = SQLite3::Database.open File.join($cache_base_path, "wgt-2016.db")
if !$opts[:skip]
    db.execute "drop table if exists gigs;"
    rows = db.execute <<-SQL
        create table gigs (
            id int,
            url varchar(255),
            artist varchar(255),
            country varchar(8),
            location varchar(255),
            street varchar(255),
            ts datetime
        );
        create index gigs_locations_idx on gigs(location);
SQL
end

# additional data

if !$opts[:skip]
    id = 999
    additional_data.each_with_index do |location, i|
        location[:gigs].each do |gig|
            db.execute "insert into gigs (id, artist, location, ts) values (?, ?, ?, ?)",
                id - i, gig[:artist], location[:location], Time.parse(gig[:ts]).strftime("%Y-%m-%d %H:%M:%S")
        end
    end
end

# parse official data

if !$opts[:skip]
    begin
        debug sprintf("download bands\n")
        if !$opts[:cache] || ($opts[:cache] && !File.exist?(File.join($cache_base_path, "bands.html")))
            download $wgt_bands_url, File.join($cache_base_path, "bands.html")
        end
    rescue
        error sprintf("cannot download bands\n")
    end

    begin
        debug sprintf("parse bands\n")
        
        doc = Nokogiri::HTML(File.open(File.join($cache_base_path, "bands.html")).read)
        doc.css("#maincontent div[data-id]").each do |node|
            url = File.join $wgt_base_url, (node.css("a.runningorder")[0]["href"] || "")
            id  = url.gsub(/^.*?id=/,"").gsub(/&.*$/,"").to_i || 0
            urls[id] = url
            db.execute "insert into gigs (id, url) values (?, ?)", id, url
        end
    rescue
        error sprintf("cannot parse bands\n")
    end

    debug sprintf("prepare keys\n")
    download_ids = urls.keys.reject do |id|
        $opts[:cache] && File.exist?(File.join($cache_base_path, "#{id}.html"))
    end

    Parallel.each_with_index(download_ids, in_threads: 4, progress: sprintf("%-12s", "fetch")) do |id|
        begin
            download urls[id], File.join($cache_base_path, "#{id}.html")
        rescue
            error sprintf("cannot download gig #%d\n", id)
        end
    end if !download_ids.empty?

    error_ids = Array.new
    Parallel.each(urls.keys, in_threads: $num_threads, progress: sprintf("%-12s", "parse")) do |id|
        begin
            doc = Nokogiri::HTML(File.open(File.join($cache_base_path, "#{id}.html")).read)
            
            artist  = doc.css("#maincontent h2").first.text.strip.gsub(/ \(.*$/,"")
            country = doc.css("#maincontent h2").first.text.strip.gsub(/^.*\(/,"").gsub(/\).*$/,"")
            date    = doc.css("#maincontent h3").first.text.strip.gsub(/\*/,"").gsub(/^t.*$/,"").split(/\./).reverse
            
            location = ""
            street   = ""
            tram     = []
            bus      = []
            sbahn    = []
            doc.css("#maincontent div.group").each do |node|
                node_text = node.text.strip
                if node_text.match(/^Uhrzeit/) && date.count == 3
                    date.push(node.css("div.col")[1].text.strip.scan(/\d+/)).flatten!
                elsif node_text.match(/^Ort/)
                    location = node.css("div.col")[1].text.strip
                elsif node_text.match(/^Adresse/)
                    street = node.css("div.col")[1].text.strip
                elsif node_text.match(/^Straßenbahn/)
                    tram.push  node.css("div.col")[1..2].map{ |x| x.text.strip }
                elsif node_text.match(/^Bus/)
                    bus.push   node.css("div.col")[1..2].map{ |x| x.text.strip }
                elsif node_text.match(/^S-Bahn/)
                    sbahn.push node.css("div.col")[1..2].map{ |x| x.text.strip }
                end
            end
            
            date = [1970, 1, 1, 0, 0] if date.count != 5
            time = Time.new(*date).strftime("%Y-%m-%d %H:%M:%S")
            
            db.execute "update gigs set artist = ?, country = ?, location = ?, street = ?, ts = ? where id = ?",
                artist, country, location, street, time, id
        rescue
            error_ids.push id
        end
    end
    error sprintf("error parsing gig keys: %s\n", error_ids.join(", ")) if error_ids.count > 0
end

# create pdf

locations = db.execute("select distinct location from gigs order by location asc").flatten
dates = (0..4).to_a.map{ |i| Time.new(2016,5,12,8,0) + i*60*60*24 }

yoffset = 30
xoffset =  0
nx = (locations.count.to_f / 2.0).ceil.to_i
pw = 297.send(:mm)
ph = 210.send(:mm)
bw = (pw - xoffset) / nx
bh = (ph - yoffset) / 2

Prawn::Font::AFM.hide_m17n_warning = true
pdf = Prawn::Document.new(:page_size => "A4", :page_layout => :landscape, :margin => 1)

dates.each_with_index do |date, j|
    options = {
        :width  => pw - 2 * 10,
        :height => yoffset,
        :at     => [10, ph]
    }
    
    pdf.font "Courier"
    pdf.text_box Time.now.strftime("%Y-%m-%d  %H:%M"), options.merge({
        :align => :right, :valign => :center, :size => 6
    })
    pdf.text_box "https://github.com/rhasqx/wgt/", options.merge({
        :align => :left, :valign => :center, :size => 6
    })
    pdf.font "Helvetica"
    pdf.text_box i18n(date.strftime("%A"))+", "+date.strftime("%d.%m.%Y"), options.merge({
        :align => :center, :valign => :center, :size => 8, :style => :bold
    })

    pdf.stroke do
        pdf.stroke_color "aaaaaa"
        pdf.line_width 0.125
        
        1.upto(nx-1).each { |i| pdf.vertical_line 0, ph - yoffset + 5, :at => xoffset + i * bw }
        
        0.upto(1).each { |i| pdf.horizontal_line 0, pw, :at => ph - yoffset +  5 - i * bh }
        0.upto(1).each { |i| pdf.horizontal_line 0, pw, :at => ph - yoffset - 10 - i * bh }
    end

    locations.each_with_index do |location, i|
        x = xoffset + i % nx * bw
        y = ph - bh * i.div(nx) - yoffset
        options = {
            :width  => bw,
            :height => bh,
            :at     => [x, y],
            :size   => 6
        }
        pdf.text_box location.truncate(20), options.merge({:align => :center, :valign => :top, :style  => :bold})

        query = sprintf "select ts, artist from gigs where %s and %s order by ts",
                    cond_date(date), cond_location(location)
        result = db.execute(query)
        gigs = Hash.new
        11.upto(23).each { |x| gigs[x] = "" }
        0.upto(3).each{ |x| gigs[x+24] = "" }
        result.each do |gig|
            hh = gig[0][11..12].to_i
            hh += 24 if hh < 11
            gigs[hh] += "\n" if !gigs[hh].empty?
            gigs[hh] += "%-5s  %-s" % [gig[0][11..15], gig[1].truncate(21)]
        end
        gigs.each do |hh, str|
            pdf.text_box str, options.merge({
                :align => :left, :valign => :top,
                :size => 5,
                :at => [x + 2, y - 15 - (hh - 11) * 20]
            })
        end
    end

    pdf.start_new_page if j < dates.count-1
end

pdf.render_file "wgt-2016.pdf"
