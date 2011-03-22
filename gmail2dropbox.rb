require 'rubygems'
require 'gmail'
require 'dropbox'
require 'yaml'

#load yaml config file

config_file = ARGV[0]
config_file = File.dirname(__FILE__) + "/conf.yaml" if (config_file == nil && File.exists?(File.dirname(__FILE__) + "/conf.yaml"))

raw_config = nil
raw_config = File.read(config_file) if (config_file != nil)

raise RuntimeError, 'Could not load config file' if raw_config == nil

CONFIG_HASH = YAML.load(raw_config)

def start_dropbox_session(args)
  return nil if (args["dropbox_oauth_file"] == nil || args["dropbox_key"] == nil || args["dropbox_secret"] == nil)
  
  #if we can't get anything useful out of the dropbox serialized oauth file, we need to generate a new session and serialize it there
  dropboxSession = nil
  dropboxSerializedData = nil
  if (File.exists? args["dropbox_oauth_file"])
    file = File.open(args["dropbox_oauth_file"])
    dropboxSerializedData = ""
    file.each {|line| dropboxSerializedData << line }
    dropboxSerializedData = nil if (dropboxSerializedData.length == 0)
    file.close
  end

  if (dropboxSerializedData == nil)
    dropboxSession = Dropbox::Session.new(args["dropbox_key"], args["dropbox_secret"])
    puts "Now visit #{dropboxSession.authorize_url}. Hit enter when you have completed authorization."
    gets
    dropboxSession.authorize
    File.open(args["dropbox_oauth_file"], 'w') {|f| f.write(dropboxSession.serialize()) }
  else
    dropboxSession = Dropbox::Session.deserialize dropboxSerializedData
  end
  
  dropboxSession 
end

def start_gmail_session(args)
  Gmail.new(args["user"], args["password"])
end

dropbox_session = start_dropbox_session CONFIG_HASH["settings"]
gmail_session = start_gmail_session CONFIG_HASH["settings"]
all_emails = gmail_session.inbox.emails(:unread, :after => Date.parse(Time.at(CONFIG_HASH["settings"]["last_run"]).strftime('%Y/%m/%d')))

newestTime = CONFIG_HASH["settings"]["last_run"]

CONFIG_HASH["settings"]["matching_trigger"] = "(for)\s+(dropbox)" if CONFIG_HASH["settings"]["matching_trigger"] == nil #perform legacy transition

CONFIG_HASH["settings"]["matching_trigger"] = Regexp.new CONFIG_HASH["settings"]["matching_trigger"] #compile regex for performance

all_emails.each do |email|
  matching_source = email.subject
  
  #perform lookup based on email aliasing
  if (CONFIG_HASH["settings"]["use_email_alias"] == true)
    matching_source = nil
    email.to_addrs.each {|to_addr| matching_source = to_addr[to_addr.index("+") + 1, to_addr.index("@") - to_addr.index("+") - 1] if (to_addr.index("+") != nil) }
    matching_source.gsub!(/[+]/," ") if matching_source != nil
  end
  
  if (matching_source != nil && matching_source.match(CONFIG_HASH["settings"]["matching_trigger"]) != nil)
    #determine mapping to use
    matched_mappings = []
    CONFIG_HASH["mappings"].keys.each { |mapping_name| matched_mappings << mapping_name if matching_source.downcase.gsub(/[^A-Za-z0-9]/, "").match(mapping_name.downcase.gsub /[^A-Za-z0-9]/, "") != nil }
    matched_mappings << "default" if matched_mappings.size == 0
    
    #group if more than one attachment
    extra_folder = ""
    if (email.attachments.size > 1 && CONFIG_HASH["settings"]["group_by_subject"] == true && CONFIG_HASH["settings"]["use_email_alias"] == true)
        extra_folder = "/" + email.subject.gsub(/[^A-Za-z0-9_ ]/,"") #group by a sensible subject name
    end
    
    #store
    email.attachments.each do |attachment|
      match_attempt = attachment.header["Content-Disposition"].to_s.match(/.*filename=(.*).*/)
      file_name = match_attempt[1]
      file_name.gsub! /["'?]*/, ""
      data_stream = StringIO.new(attachment.body.to_s)
      matched_mappings.each { |key| dropbox_session.upload(data_stream, "/#{CONFIG_HASH["mappings"][key]}#{extra_folder}", :mode => :dropbox, :as => file_name) }
    end
    
    newestTime = email.date.to_i if email.date != nil && email.date.to_i > newestTime #store the most recent processed email
    
    #clean up inbox
    email.mark(:read)
  end
end

CONFIG_HASH["settings"]["last_run"] = newestTime #update

#Save back to file
File.open(config_file, 'w') {|f| f.write(CONFIG_HASH.to_yaml) }