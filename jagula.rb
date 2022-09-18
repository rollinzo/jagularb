require 'yaml'
require 'erb' 
require 'pry'
require 'faraday'
require 'nokogiri'

class Author
  def initialize(hash = {})
    hash.keys.each do |key|
      self.instance_variable_set("@#{key}", hash[key])
      self.class.send(:define_method, key.to_sym) do
          instance_variable_get "@#{key}"
      end
    end
  end
end


class Entry
  def initialize(hash = {})
    hash.keys.each do |key|
      self.instance_variable_set("@#{key}", hash[key])
      self.class.send(:define_method, key.to_sym) do 
          instance_variable_get "@#{key}"
      end
    end
    set_author
    @output_directory = nil
  end
  
  def set_output_directory(dir_name)
    @output_directory = dir_name
  end

  def output_directory
    @output_directory
  end

  def set_page_content(page_html)
    @page_content = page_html
  end

  def page_content
    @page_content
  end

  def set_author
    author_link = self._links["author"][0]["href"]
    @author = Author.new(JSON.parse(Faraday.get(author_link).body))
  end

  def get_binding
    binding
  end
end

class JagularPage
  
  def initialize(jagular_obj, page_config, page_content)
    @my_jagular = jagular_obj

  end

end


class Jagular

  
  def initialize
    #pull in config.yaml
    config_file = File.open("./config.yaml", "r")
    config_data = config_file.read
    @config = YAML.load(config_data)
    config_file.close
    @config["template_path"].length > 0 ? @config["template_path_set"] = true : @config["template_path_set"] = false
    `mkdir #{@config["output_path"]}` if !Dir.exists?(@config["output_path"])
    @last_updated = get_last_updated
    fetch_and_load_helpers
  end

  def fetch_and_load_helpers
    @config["pages"].keys.each do |k|
      helper_file = get_helper_file(k)
      module_name = get_helper_module_name(k)
      if (helper_file != nil) && (module_name != nil)
        require_relative @config["helper_path"] + helper_file
        #new way: helpers are stand alone modules
        #we pass a reference to our jagular object
        curr_mod = Module.const_get(module_name)
        curr_mod.class.send(:define_method, :jagular_obj) do
          self
        end
        #Helpers should respond to ::run_helper
        
        #in future, to expand Jagular's functionality, check for @config["extensions"] and load and include module extensions
        #old way: helpers as modules to be included
        #self.class.class_eval do
        #  include Module.const_get(module_name)
        #end
      end
    end 
  end

  def get_helper_file(page_key)
    if (@config["pages"][page_key].has_key?("helper") && @config["pages"][page_key]["helper"].has_key?("file"))
      return @config["pages"][page_key]["helper"]["file"]
    else
      return nil
    end
  end

  def get_helper_module_name(page_key)
    if (@config["pages"][page_key].has_key?("helper") && @config["pages"][page_key]["helper"].has_key?("module_name"))
      return @config["pages"][page_key]["helper"]["module_name"]
    else
      return nil
    end
  end

  def get_last_updated
    if File.exists?(@config["timestamp_last_updated"])
      file = File.open(@config["timestamp_last_updated"], "r")
      last_updated = file.readline.chomp!.to_i 
      file.close
    else
      last_updated = @config["starting_time"]
    end
    return last_updated
  end
 
  def get_posts
    resp = Faraday.get(@config['json_api'] + 'wp-json/wp/v2/posts')
    posts_json = JSON.parse(resp.body)
  end


  def pull_template(template)
    if @config["template_path_set"]
     my_template_path = @config["template_path"] + @config[template]["in"]
    else
     my_template_path = "./" + @config[template]["in"]
    end
    template_file = File.open(my_template_path, "r")
    file_erb = template_file.read
    template_file.close
    return file_erb
  end

  def outfile_name(entry, template)
    if match = /\$(.*)\$/.match(template["out"])
      return template["out"].gsub(match[0], entry.send(match[1].to_sym))
    else
      return template["out"]
    end
  end

  def layout_page(entry, template = "layout_default")
    layout_erb = pull_template(template)
    layout_rhtml = ERB.new(layout_erb)
    layout_rhtml.result(entry.get_binding)
  end

  def print_page(entry, template_name)
    template_erb = pull_template(template_name)
    page_html = ERB.new(template_erb)
    entry.set_page_content page_html.result(entry.get_binding)
    output_html = copy_and_replace_images(layout_page(entry))
    output_file_path = @config["output_path"] + output_directory(entry.output_directory) + outfile_name(entry, @config[template_name])
    out_file = File.open(output_file_path, "w")
    File.write(out_file, output_html)
    out_file.close

  end

  def create_new_image_path(old_image_path)
    #split based on match up including to wp-content/uploads
    my_match = /^http.*wp-content\/uploads\/(\d*\/\d*\/)(.*)/.match(old_image_path)
    filename = my_match[2]
    month_day = my_match[1]
    fetch_url = @config["json_api"] + "wp-content/uploads/" + month_day + filename
    `mkdir #{@config["output_path"] + @config["images_directory"]}` if !Dir.exists?(@config["output_path"] + @config["images_directory"])
    write_path = @config["output_path"] + @config["images_directory"] + filename
    resp = Faraday.get(fetch_url)
    File.open(write_path, 'wb') { |wp| wp.write(resp.body) } 
    return @config["images_directory"] + filename
  end

  def copy_and_replace_images(page_html)
  # since the #to_html method dumps an entire html doc, need to run this method after layout+page have been generated
    ndoc = Nokogiri::HTML(page_html)
    images = ndoc.search("img")
    images.each do |i|
       new_image_path = create_new_image_path(i.get_attribute "src")
        i.set_attribute("src", new_image_path)
    end
     ndoc.to_html
  end




  def output_directory(output_dir)
    if output_dir
      `mkdir #{@config["output_path"] + output_dir}` if !Dir.exists(@config["output_path"] + output_dir)
       return output_dir
    else
       return ""
    end
  end

  def wp_timestamp_to_epoch(wp_timestring)
    DateTime.parse(wp_timestring).to_time.to_i
  end

  def get_and_print_posts
    resp = Faraday.get(@config["json_api"] + "wp-json/wp/v2/posts")
    posts = JSON.parse(resp.body)
    posts.each do |p| 
     if wp_timestamp_to_epoch(p["date"]) > @last_updated
        entry = Entry.new(p)
        print_page(entry, "page_default")
        puts "printing #{entry.title['rendered']}"
      end
    end
    run_update
  end

  def run_update


    `echo #{Time.now.to_i.to_s} > #{@config["timestamp_last_updated"]}`
  end


end #end of class

  jrb = Jagularb.new
#  jrb.get_and_print_posts
