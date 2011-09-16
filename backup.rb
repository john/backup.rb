# Usage:
#
#  - Put in #{RAILS_ROOT}/lib
#
#  - If you're using S3 to store backups, puts your S3 credentials in /config/s3.yml
#
#  - Set the values for these constants:
#    + S3 to true if you want backups moved to S3.
#    + BACKUPS for the number of backups you want to save. Once this many have been archived, older ones are deleted for each new backup added. Set to 0 to save everything.
#    + APP for the app name. Used by mysql and S3.
#    + TABLES and FULL for where local mysqldumps are put.
#
#  - Call with no arguments to back up entire db, or pass in table names as arguments to back up only those tables:
#    ruby backup.rb
#    ruby backup.rb table1 table2
#
#  - Restore thusly:
#    gunzip < ~/2011-09-09-07_37_01.sql.gz | mysql -u root reputedly_production
#
#  - Cron this script for automated backups. Example crontab entries:
#
#  backup 'github' and 'twitter' tables every half hour, as root user, piping output to dev/null:
#  */30 * * * * cd /apps/phu/current/lib && ruby backup.rb github twitter >> /dev/null 2>&1
#
#  backup entire db every 4 hours, ten minutes after the hour.
#  10 */4 * * * cd /apps/phu/current/lib && ruby backup.rb

#  backup entire db every night at 3am.
#  * 3 * * * root cd /apps/phu/current/lib && ruby backup.rb

require 'fileutils.rb'
require 'rubygems'
require 'aws/s3'
require 'yaml'
require 'erb'

S3 = true
BACKUPS = 5 # set to 0 if you want to save everything rather than rotating

RAILS_ENV = 'production'
APP = 'reputedly'
DATA_DIR = '../db/data'

db_config ||= YAML::load(ERB.new(IO.read("../config/database.yml")).result)[RAILS_ENV]

puts 'running mysqldump'
db_args = "-u #{db_config['username']} -p#{db_config['password']} -h #{db_config['host']} #{db_config['database']}"

if ARGV.size > 0
  FileUtils.mkdir_p "#{DATA_DIR}/tables"
  dump_to = "#{DATA_DIR}/tables/*.sql.gz"
  s3_path = "reputedly/tables"
  `mysqldump #{db_args} #{ARGV.join(' ')} | gzip > #{DATA_DIR}/tables/#{ARGV.join('-')}-#{Time.now.strftime('%Y-%m-%d-%H_%M_%S')}.sql.gz`
else
  FileUtils.mkdir_p "#{DATA_DIR}/full"
  dump_to = "#{DATA_DIR}/full/*.sql.gz"
  s3_path = "reputedly/full"
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