#!/usr/bin/env ruby
require 'openssl'
require 'google/apis/calendar_v3'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'fileutils'
require 'pp'
require_relative './rooms'

cert_path = Gem.loaded_specs['google-api-client'].full_gem_path+'/lib/cacerts.pem'
ENV['SSL_CERT_FILE'] = cert_path

people = ARGV
if people.size == 0
  puts <<EOT
Hey Josh!
You need to tell me who to book. Just enter them in in a space-separated list. Like this:

be ruby create-1-1s.rb someone someone_else etc

I'll add the @optoro.com to their names if you leave that off

Have a great day!!! :D
EOT
  exit
end
people = people.map do |p|
  p =~ /@/ ? p : "#{p}@optoro.com"
end

# just a secret function so I don't give out all the room IDs I've saved locally. It's a PITA, thanks google.
# This function returns an array like:
# [ {c: "google calendar room email address", cn: "room short name" } ]
@rooms = get_rooms

@preferred_times = [
  ["monday", 9,0, 11,0],
  ["monday", 15,0, 17,0],
  ["tuesday", 14,0, 17,0],
  ["thursday", 9,0, 17,0],
  ["friday", 13,0, 17,0],
]

MEETING_LEN_MIN = 30
TIME_ZONE = "America/New_York"
MY_EMAIL = 'jszmajda@optoro.com'
MY_SHORT_NAME = 'joshsz'


SCOPE = Google::Apis::CalendarV3::AUTH_CALENDAR
##
# Ensure valid credentials, either by restoring from the saved credentials
# files or intitiating an OAuth2 authorization. If authorization is required,
# the user's default browser will be launched to approve the request.
#
# @return [Google::Auth::UserRefreshCredentials] OAuth2 credentials
def authorize
  oob_uri = 'urn:ietf:wg:oauth:2.0:oob'
  client_secrets_path = 'client_secret.json'
  credentials_path = "calendar-credentials.yaml"
  client_id = Google::Auth::ClientId.from_file(client_secrets_path)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: credentials_path)
  authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store)
  user_id = 'default'
  credentials = authorizer.get_credentials(user_id)
  if credentials.nil?
    url = authorizer.get_authorization_url(base_url: oob_uri)
    puts "Open the following URL in the browser and enter the resulting code after authorization"
    puts url
    code = gets
    credentials = authorizer.get_and_store_credentials_from_code(user_id: user_id, code: code, base_url: oob_uri)
  end
  credentials
end

puts "Logging in..."
# Initialize the API
service = Google::Apis::CalendarV3::CalendarService.new
service.client_options.application_name = 'console-calendar'
service.authorization = authorize

# Fetch the next 10 events for the user
calendar_id = 'primary'



def next_boundary(time)
  if time.min < 30
    Time.new(time.year, time.month, time.day, time.hour, 30, 0)
  else
    next_hour = time + (60*60)
    Time.new(next_hour.year, next_hour.month, next_hour.day, next_hour.hour, 0, 0)
  end
end

# returns a list of free rooms at the time given
def find_free_rooms(time, busy)
  overlaps = busy.select{|e| e[:s] <= time && e[:e] > time }
  etime = time + (MEETING_LEN_MIN * 60)
  overlaps += busy.select{|e| e[:s] < etime && e[:e] > time }

  rooms_busy, people_busy = overlaps.partition{|e| e[:r] }
  #pp [people_busy, rooms_busy]
  return [] if people_busy.size > 0 || rooms_busy.size == @rooms.size

  busy_ids = rooms_busy.map{|b| b[:c] }
  @rooms.reject{|r| busy_ids.include?(r[:c]) }
end

def add_preferred_busy_to_busy(busy)
  # group busy by day
  # each busy day:
  #   what weekday is it
  #   find preferred times in that weekday
  #   black out all non-preferred times that day
  #   add to list of additions
  # return busy + additions
  additions = []
  busy.chunk{|b| b[:s].yday }.each do |yday,day|
    s = day.first[:s]
    pref_ranges = @preferred_times.select{|t| day.first[:s].send("#{t[0]}?") }
    #pp pref_ranges
    if pref_ranges.size > 0
      a = pref_ranges[0]
      st = Time.new(s.year, s.month, s.day, 0, 0, 0)
      en = Time.new(s.year, s.month, s.day, a[1], a[2], 0)
      #pp [st, en]
      additions << { c: MY_EMAIL, r: false, cn: MY_EMAIL, s: st, e: en }
      pref_ranges << [pref_ranges[0][0], 23,59, 23,59]
    end
    pref_ranges.each_cons(2) do |a, b|
      st = Time.new(s.year, s.month, s.day, a[3], a[4], 0)
      en = Time.new(s.year, s.month, s.day, b[1], b[2], 0)
      #pp [st, en]
      additions << { c: MY_EMAIL, r: false, cn: MY_EMAIL, s: st, e: en }
    end
  end
  #pp additions
  busy + additions
end

def find_free(busy, next_start = Time.now)
  # start at nearest 30-minute boundary
  # if busy, move in 30-minute windows
  # if all free (no busy elements bound current time), search in 30-minute windows for next busy overlap
  # when overlap is found, write down free period, look for next start
  next_start = next_boundary(next_start)
  100.times do |i|
    free = find_free_rooms(next_start, busy)
    return {free_at: next_start, rooms: free} if free.size > 0
    next_start = next_boundary(next_start + 1)
  end
  nil
end

def ask_book_a_room(all_busy, person)
  search_time = Time.now
  loop do
    puts "searching from #{search_time}"
    booking_opp = find_free(add_preferred_busy_to_busy(all_busy), search_time)
    return nil unless booking_opp
    free_at = booking_opp[:free_at]
    if !free_at.saturday? && !free_at.sunday?

      puts "Booking Opportunity!"
      puts "    You and #{person}"
      puts "    #{booking_opp[:free_at]}"
      puts "    Rooms Free: #{booking_opp[:rooms].map{|r| r[:cn]}.join(", ")}"
      puts "Accept? (Y/N)"
      accept = STDIN.gets
      if accept =~ /(y|Y)/
        room = booking_opp[:rooms][0]
        puts "Booking #{room[:cn]}!..."
        return {at: free_at, room: room}


      end
    end
    search_time = booking_opp[:free_at] + 1
  end
end

now = Time.now
puts "Fetching Calendars..."
my_calendar = service.get_calendar('primary')
room_calendars = (@rooms.map{|e| e[:c]}).map{|e| service.get_calendar(e) }
puts "Booking #{people.join(", ")}"
people.each do |person|
  person_calendar = service.get_calendar(person)
  calendars = [person_calendar, my_calendar] + room_calendars
  free_busy_request = Google::Apis::CalendarV3::FreeBusyRequest.new(time_min: now.iso8601, time_max: (now + (7 * 24 * 60 * 60)).iso8601, time_zone: TIME_ZONE, items: calendars.map{|c| {id: c.id}} )
  response = service.query_freebusy(free_busy_request)

  all_busy = response.calendars.map{|e| e[1].busy.map do |b|
    room = !!( e[0] =~ /resource/ )
    {c: e[0], r: room, cn: (room ? @rooms.find{|r| r[:c] == e[0]}[:cn] : e[0]), s: b.start.to_time, e: b.end.to_time}
  end }.flatten.compact

  #pp response
  if booking = ask_book_a_room(all_busy, person)
    at = booking[:at]
    person_short_name = person.sub(/@.*/,'')
    room_cal = room_calendars.find{|c| c.id == booking[:room][:c] }
    event = Google::Apis::CalendarV3::Event.new({
      summary: "#{MY_SHORT_NAME} <> #{person_short_name} 1-1",
      location: room_cal.summary,
      description: "Let's chat!",
      start: { date_time: at.iso8601, time_zone: TIME_ZONE},
      end: { date_time: (at + (MEETING_LEN_MIN * 60)).iso8601, time_zone: TIME_ZONE},
      attendees: [
        {email: MY_EMAIL},
        {email: person},
        {email: room_cal.id},
      ]
    })

    service.insert_event('primary', event)
  end
end

