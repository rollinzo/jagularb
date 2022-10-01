require 'yaml'
require 'erb'
require 'pry'
require 'faraday'
require 'nokogiri'


class Jagular

  def initialize
     #pull in config.yaml
    config_file = File.open("./config.yaml", "r")
    config_data = config_file.read
    @config = YAML.load(config_data)
    config_file.close
    @config["template_path"].length > 0 ? @config["template_path_set"] = true : @config["template_path_set"] = false
    #`mkdir #{@config["output_path"]}` if !Dir.exists?(@config["output_path"])
    #@last_updated = get_last_updated
    @globals = {}
    @globals["site_url"] = @config["site_url"]
    @globals["assets_url"] = @config["site_url"] + "assets/"
    @globals["css_url"] = @config["site_url"] + "css/"
    @pages = get_pages
    #add page config to pages 
    @pages.each do |page|
      page["globals"] = @globals
      if @config["pages"].include? page["slug"]
        template_name = @config["pages"][page["slug"]]
        page["template"] = @config["templates"][template_name]
      else
        page["template"] = @config["templates"]["page_default"]
      end
    
    end
    fetch_and_load_helpers

  end
  
  #PULL JSON FROM WORDPRESS
  
  def get_pages_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/pages').body

  end

  def get_posts_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/posts').body
  end

  def get_pages
    return JSON.parse(get_pages_json_from_api)
  end

  def get_posts
    return JSON.parse(get_posts_json_from_api)
  end

  


  #LOAD HELPERS

  def fetch_and_load_helpers
    @pages.each do |page|
      if page["template"]["helper"] != nil
        helper_file = get_helper_file(page)
        helper_name = get_helper_module_name(page)
        if (helper_file != nil) && (helper_name != nil)
          require_relative @config["helper_path"] + helper_file
          curr_mod = Module.const_get(helper_name)
          mod_obj = curr_mod.send(:new, self)
          page["template"]["helper"]["obj"] = mod_obj
          page["template"]["helper"]["function"] = mod_obj.get_helper_function
        end
      else

        #assign default helper
        page["template"]["helper"] ={}
        page["template"]["helper"]["obj"] = Object.new
        page["template"]["helper"]["function"] = Proc.new { {} }
      end
    end
  end

  def get_helper_file(page)
    if (page.has_key?("template")) && (page["template"].has_key?("helper") && page["template"]["helper"].has_key?("file"))
      return page["template"]["helper"]["file"]
    else
      return nil
    end
  end

  def get_helper_module_name(page)
    if (page.has_key?("template")) && (page["template"].has_key?("helper") && page["template"]["helper"].has_key?("module_name"))
      return page["template"]["helper"]["module_name"]
    else
      return nil
    end
  end




  #PAGE BUILDING

  def build_pages
    render_css
    build_assets
    @pages.each do |page|
      #helper function added in load_helpers, called in initialie
      page["content_hash"] = page["template"]["helper"]["function"].call()
      page["final_assets_path"] = "./assets/"
      page["content_hash"]["rendered_entry"] = render_entry_html(page)
      layout_html = render_layout(page)
      #final_html = copy_and_replace_images(layout_html, page["slug"]+"/")
      #file_path = write_entry_to_file(page, final_html)
      write_entry_to_file(page, layout_html)
    
    end
  end

  def build_assets
    `cp -r #{@config["assets_path"]} #{@config["output_path"] + "."}`
    #@config["templates"].keys.each do |key|

     # template = @config["templates"][key]
     # if template["assets_dir"] && Dir.exists?(@config["assets_path"] + template["assets_dir"])
     #   binding.pry
     #   assets_out = @config["output_path"] + template["assets_dir"]
     #   assets_in = @config["assets_path"] + template["assets_dir"] 
     #   `mkdir -p #{assets_out}`
     #   `cp -r #{assets_in} #{@config["output_path"]+"."}`
   
     # end
    #end
  end

  def render_css
    `mkdir #{@config["output_path"]+"css/"}`
    Dir.children(@config["css_path"]).each do |filename| 
      my_match = /.*\.erb$/.match(filename)
      if !my_match.nil?
        f = File.open(@config["css_path"]+filename, "r")
        file_contents = f.read 
        f.close
        my_css = erb2css(file_contents)
        filename2 = filename.gsub(/\.erb$/, "")
        File.write(@config["output_path"] + @config["css_path"] + filename2, my_css)
      else
       `cp #{@config["css_path"]+filename} #{@config["output_path"] + @config["css_path"] + filename}`
      end
    end
  end

  def erb2css(erbfile_contents)
    rcss = ERB.new(erbfile_contents)
    return rcss.result_with_hash({"globals" => @globals})

  end


  def pull_template_erb(template_file_name)
    if @config["template_path_set"]
     my_template_path = @config["template_path"] + template_file_name
    else
     my_template_path = "./" + template_file_name
    end
    template_file = File.open(my_template_path, "r")
    file_erb = template_file.read
    template_file.close
    return file_erb
  end

   def render_entry_html(entry)
     entry_erb = pull_template_erb(entry["template"]["in"])
     entry_rhtml = ERB.new(entry_erb)
     #helper function content is rendered in entry["content_hash"]
     return entry_rhtml.result_with_hash(entry)
  end

  def render_layout(entry)
    layout_erb = pull_template_erb(@config["templates"]["layout_default"]["in"])
    layout_rhtml = ERB.new(layout_erb)
    return layout_rhtml.result_with_hash(entry)
  end

  def outfile_name(entry)
    template = entry["template"]
    if match = /\$(.*)\$/.match(template["out"])
        return template["out"].gsub(match[0], entry[match[1]])
    end
    return template["out"]

  end


  def write_entry_to_file(entry, html)
    if entry["template"].has_key? "directory"
      output_file_path = @config["output_path"] + entry["template"]["directory"] + outfile_name(entry, @config[template_name])
    else
      output_file_path = @config["output_path"] + outfile_name(entry)
    end
    out_file = File.open(output_file_path, "w")
    File.write(out_file, html)
    out_file.close
    return output_file_path
 end

  def create_new_image_path(old_image_path, entry_image_dir)
    #TODO: check for entry_image_dir and create if need to

    #split based on match up including to wp-content/uploads
    my_match = /^http.*wp-content\/uploads\/(\d*\/\d*\/)(.*)/.match(old_image_path)
    filename = my_match[2]
    month_day = my_match[1]
    fetch_url = @config["json_api"] + "wp-content/uploads/" + month_day + filename
    `mkdir #{@config["output_path"] + @config["images_directory"]}` if !Dir.exists?(@config["output_path"] + @config["images_directory"])
    write_path = @config["output_path"] + @config["images_directory"] + entry_image_dir + filename
    resp = Faraday.get(fetch_url)
    File.open(write_path, 'wb') { |wp| wp.write(resp.body) }
    return @config["images_directory"] + filename
  end

  def copy_and_replace_images(page_html, entry_image_dir)
  # since the #to_html method dumps an entire html doc, need to run this method after layout+page have been generated
    ndoc = Nokogiri::HTML(page_html)
    images = ndoc.search("img")
    images.each do |i|
       #check if this image is from our wordpress
       #match against @config["replace_image_urls"]
       #easy with this? Regexp.new @config["json_api"] + "uploads"
       #create_new_image_path(i.get_attribute "src", my_regex, entry_image_dir)
       new_image_path = create_new_image_path(i.get_attribute "src", entry_image_dir)
        i.set_attribute("src", new_image_path)
    end
     ndoc.to_html
  end



end

jrb = Jagular.new
binding.pry
