require 'bundler'

Bundler.require
require 'json'
require 'rack/attack'
require 'redis'
require 'sinatra/reloader'

require 'dotenv'
Dotenv.load

REDIS = Redis.new(url: ENV.fetch('REDIS_URL'))

DB = Sequel.connect(ENV.fetch('DATABASE_URL').sub(%r{mysql://}, 'mysql2://'), charset: 'utf8')

use Rack::Attack
Rack::Attack.cache.store = Rack::Attack::StoreProxy::RedisStoreProxy.new(REDIS)

Rack::Attack.throttle('requests by ip', limit: 15, period: 30) do |request|
  request.ip
end

set :protection, except: [:json_csrf]

def get_verse_id(ref, translation_id, last = false)
  record = DB[
    'select id from verses ' \
    "where book_id = :book and chapter = :chapter #{ref[:verse] ? 'and verse = :verse' : ''} " \
    'and translation_id = :translation_id ' \
    " #{last ? 'order by id desc' : ''} limit 1",
    ref.update(translation_id: translation_id)
  ].first
  record ? record[:id] : nil
end

def get_verses(ranges, translation_id)
  all = []
  ranges.each do |(ref_from, ref_to)|
    start_id = get_verse_id(ref_from, translation_id)
    stop_id  = get_verse_id(ref_to, translation_id, :last)
    return nil unless start_id && stop_id
    all += DB['select * from verses where id between ? and ?', start_id, stop_id].to_a
  end
  all
end

def get_translation
  translation = DB['select * from translations where identifier = ?', params[:translation] || 'WEB'].first
  unless translation
    status 404
    response = { error: 'translation not found' }
    return response
  end
  translation
end

# Use /?random=verse to generate a random verse.
def get_random_verse
  if params[:random] != "verse"
    nil
  else
    translation = get_translation
    return jsonp(translation[:error]) if translation[:error]

    books_size = DB['select book_num from verses where translation_id = ? order by book_num desc limit 1;', translation[:id]].first[:book_num]
    book_num = rand(books_size) + 1
    book = DB['select book from verses where translation_id = ? && book_num = ?;', translation[:id], book_num].first[:book]

    chapters_size = DB['select chapter from verses where translation_id = ? && book_num = ? order by chapter desc limit 1;', translation[:id], book_num].first[:chapter]
    chapter = rand(chapters_size) + 1

    verses_size = DB['select verse from verses where translation_id = ? && book_num = ? && chapter = ? order by verse desc limit 1;', translation[:id], book_num, chapter].first[:verse]
    verse = rand(verses_size) + 1
    "#{book} #{chapter}:#{verse}"
  end
end

# pulled from sinatra-jsonp and modified to return a UTF-8 charset
module Sinatra
  module Jsonp
    def jsonp(*args)
      if args.size > 0
        data = MultiJson.dump args[0], :pretty => settings.respond_to?(:json_pretty) && settings.json_pretty
        if args.size > 1
          callback = args[1].to_s
        else
          ['callback','jscallback','jsonp','jsoncallback'].each do |x|
            callback = params.delete(x) unless callback
          end
        end
        if callback
          callback.tr!('^a-zA-Z0-9_$\.', '')
          content_type 'text/javascript', charset: 'utf-8'
          response = "#{callback}(#{data})"
        else
          content_type 'application/json', charset: 'utf-8'
          response = data
        end
        response
      end
    end
  end
  helpers Jsonp
end

get '/' do
  unless DB.table_exists?(:verses)
    return 'please run import.rb script according to README'
  end
  if params[:random]
    ref_string = get_random_verse
    if ref_string.nil?
      status 404
      response = { error: 'unrecognized value for parameter' }
      return jsonp(response)
    else
      display_verse_from(ref_string)
    end
  else
    @translations = DB['select id, identifier, language, name from translations order by language, name']
    books = DB["select translation_id, book from verses where book_id = 'JHN' group by translation_id, book"]
    @books = books.each_with_object({}) do |book, hash|
      hash[book[:translation_id]] = book[:book]
    end
    https = request.env['HTTP_X_FORWARDED_PROTO'] =~ /https/
    @host = (https ? 'https://' : 'http://') + (request.env['SERVER_NAME'] || 'bible-api.com') + '/'
    erb :index
  end
end

options "/:ref" do
  headers 'Access-Control-Allow-Origin' => '*',
          'Access-Control-Allow-Methods' => ['OPTIONS', 'GET']
  200
end

get '/:ref' do
  content_type 'application/json', charset: 'utf-8'
  headers 'Access-Control-Allow-Origin' => '*',
          'Access-Control-Allow-Methods' => ['OPTIONS', 'GET']
  ref_string = params[:ref].tr('+', ' ')
  display_verse_from(ref_string)
end

def display_verse_from(ref_string)
  translation = get_translation
  return jsonp(translation[:error]) if translation[:error]
  vn = params[:verse_numbers]
  ref = BibleRef::Reference.new(ref_string, language: translation[:language_code])
  if (ranges = ref.ranges)
    if (verses = get_verses(ranges, translation[:id]))
      verses.map! do |v|
        {
          book_id:   v[:book_id],
          book_name: v[:book],
          chapter:   v[:chapter],
          verse:     v[:verse],
          text:      v[:text]
        }
      end
      verse_text = if vn == 'true'
                     verses.map { |v| '(' + v[:verse].to_s + ') ' + v[:text] }.join
                   else
                     verses.map { |v| v[:text] }.join
                   end
      response = {
        reference:        ref.normalize,
        verses:           verses,
        text:             verse_text,
        translation_id:   translation[:identifier],
        translation_name: translation[:name],
        translation_note: translation[:license]
      }
    else
      status 404
      response = { error: 'not found' }
    end
  else
    status 404
    response = { error: 'not found' }
  end
  jsonp response
end
