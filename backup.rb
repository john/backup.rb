require 'fileutils.rb'
require 'rubygems'
require 'aws/s3'
require 'yaml'
require 'erb'

S3 = true
BACKUPS = 5 # set to 0 if you want to save everything rather than rotating

RAILS_ENV = 'production'
APP = 'phu'
DATA_DIR = '../db/data'

db_config ||= YAML::load(ERB.new(IO.read("../config/database.yml")).result)[RAILS_ENV]

puts 'running mysqldump'
db_args = "-u #{db_config['username']} -p#{db_config['password']} -h #{db_config['host']} #{db_config['database']}"

if ARGV.size > 0
  FileUtils.mkdir_p "#{DATA_DIR}/tables"
  dump_to = "#{DATA_DIR}/tables/*.sql.gz"
  s3_path = "phu/tables"
  `mysqldump #{db_args} #{ARGV.join(' ')} | gzip > #{DATA_DIR}/tables/#{ARGV.join('-')}-#{Time.now.strftime('%Y-%m-%d-%H_%M_%S')}.sql.gz`
else
  FileUtils.mkdir_p "#{DATA_DIR}/full"
  dump_to = "#{DATA_DIR}/full/*.sql.gz"
  s3_path = "phu/full"
  `mysqldump #{db_args} | gzip > #{DATA_DIR}/full/#{Time.now.strftime('%Y-%m-%d-%H_%M_%S')}.sql.gz`
end

if S3
  s3_config ||= YAML::load(ERB.new(IO.read("../config/s3.yml")).result)
  AWS::S3::Base.establish_connection!( :access_key_id => s3_config[RAILS_ENV]['aws_access_key'],  :secret_access_key => s3_config[RAILS_ENV]['aws_secret_access_key'] )

  @backup_files = Array.new
  Dir.glob(dump_to).each { |filename| @backup_files << File.new(filename) }
  @backup_files = @backup_files.sort{|a,b| b.mtime <=> a.mtime}

  bucket = (RAILS_ENV == 'development') ? "rgdb-dev" : "rgdb"
  puts "Moving '#{File.basename(@backup_files.first.path)}' to S3 bucket '#{bucket}'"
  
  AWS::S3::Bucket.create(bucket, :access => :public_read)
  AWS::S3::S3Object.store("#{s3_path}/#{File.basename(@backup_files.first.path)}", open(@backup_files.first.path), bucket, :access => :public_read) # APP here is being used as the name of the bucket
end

if BACKUPS
  @backup_files = Array.new
  Dir.glob("#{DATA_DIR}/full/*.sql.gz").each do |filename|
    file = File.new(filename)
    @backup_files << file
  end
  @backup_files = @backup_files.sort{|a,b| b.mtime <=> a.mtime}

  if @backup_files.size > 10
    @backup_files.inject(10) do |i,f|
      File.delete(@backup_files[i].path)
      i += 1
      break if i == @backup_files.size
      i
    end
  end
end