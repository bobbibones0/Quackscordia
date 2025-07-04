local uv = require("uv")
local json = require('json')
local timer = require('timer')
local http = require('coro-http')
local package = require('../../package.lua')
local Mutex = require('utils/Mutex')
local endpoints = require('endpoints')
local constants = require('constants')

local request = http.request
local f, gsub, byte = string.format, string.gsub, string.byte
local max, random = math.max, math.random
local encode, decode, null = json.encode, json.decode, json.null
local insert, concat = table.insert, table.concat
local sleep = timer.sleep
local running = coroutine.running

local API_VERSION = constants.API_VERSION
local BASE_URL = "https://discord.com/api/" .. 'v' .. API_VERSION
local JSON = 'application/json'
local PRECISION = 'millisecond'
local MULTIPART = 'multipart/form-data;boundary='
local USER_AGENT = f('DiscordBot (%s, %s)', package.homepage, package.version)

local majorRoutes = {guilds = true, channels = true, webhooks = true}
local payloadRequired = {PUT = true, PATCH = true, POST = true}

local function parseErrors(ret, errors, key)
    for k, v in pairs(errors) do
        if k == '_errors' then
            for _, err in ipairs(v) do
                insert(ret, f('%s in %s : %s', err.code, key or 'payload', err.message))
            end
        else
            if key then
                parseErrors(ret, v, f(k:find("^[%a_][%a%d_]*$") and '%s.%s' or tonumber(k) and '%s[%d]' or '%s[%q]', key, k))
            else
                parseErrors(ret, v, k)
            end
        end
    end
    return concat(ret, '\n\t')
end

local function sub(path)
    return not majorRoutes[path] and path .. '/:id'
end

local function route(method, endpoint)

    -- special case for reactions
    if endpoint:find('reactions') then
        endpoint = endpoint:match('.*/reactions')
    end

    -- remove the ID from minor routes
    endpoint = endpoint:gsub('(%a+)/%d+', sub)

    -- special case for message deletions
    if method == 'DELETE' then
        local i, j = endpoint:find('/channels/%d+/messages')
        if i == 1 and j == #endpoint then
            endpoint = method .. endpoint
        end
    end

    return endpoint

end

local function generateBoundary(files, boundary)
    boundary = boundary or tostring(random(0, 9))
    for _, v in ipairs(files) do
        if v[2]:find(boundary, 1, true) then
            return generateBoundary(files, boundary .. random(0, 9))
        end
    end
    return boundary
end

local function attachFiles(payload, files)
    local boundary = generateBoundary(files)
    local ret = {
        '--' .. boundary,
        'Content-Disposition:form-data;name="payload_json"',
        'Content-Type:application/json\r\n',
        payload,
    }
    for i, v in ipairs(files) do
        insert(ret, '--' .. boundary)
        insert(ret, f('Content-Disposition:form-data;name="file%i";filename=%q', i, v[1]))
        insert(ret, 'Content-Type:application/octet-stream\r\n')
        insert(ret, v[2])
    end
    insert(ret, '--' .. boundary .. '--')
    return concat(ret, '\r\n'), boundary
end

local mutexMeta = {
    __mode = 'v',
    __index = function(self, k)
        self[k] = Mutex()
        return self[k]
    end
}

local function tohex(char)
    return f('%%%02X', byte(char))
end

local function urlencode(obj)
    return (gsub(tostring(obj), '%W', tohex))
end

local API = require('class')('API')

function API:__init(client)
    self._client = client
    self._mutexes = setmetatable({}, mutexMeta)
    self._global_ratelimit_reset_after = 0 -- Global rate limit
end

function API:authenticate(token)
    self._token = token
    return self:getCurrentUser()
end

function API:request(method, endpoint, payload, query, files)
    local _, main = running()
    if main then
        return error('Cannot make HTTP request outside of a coroutine', 2)
    end

    local route_key = route(method, endpoint)
    local mutex = self._mutexes[route_key]
    local client = self._client

    -- --- Rate Limit Handling ---
    -- Global rate limit check (before route-specific and mutex)
    local global_wait_time = self._global_ratelimit_reset_after - uv.now()
    if global_wait_time > 0 then
        client:warning(f("Waiting for global rate limit for %i ms", global_wait_time))
        sleep(global_wait_time / 1000)
    end

    -- Check if this route is currently in a cooldown period *before* acquiring mutex
    -- This allows other coroutines waiting for different routes to proceed.
    if mutex._ratelimit_reset_after and uv.now() < mutex._ratelimit_reset_after then
        local wait_time = mutex._ratelimit_reset_after - uv.now()
        if wait_time > 0 then
            client:warning(f("Waiting for route %s due to rate limit for %i ms", route_key, wait_time))
            sleep(wait_time / 1000) -- Yield the current coroutine for the remaining cooldown
        end
    end
    -- --- End Rate Limit Handling ---

    -- Acquire the mutex for the actual request execution
    -- We wait *after* any necessary sleep to avoid holding the mutex during an idle period.
    mutex:lock()

    local url = BASE_URL .. endpoint

    if query and next(query) then
        local buf = {url}
        for k, v in pairs(query) do
            insert(buf, #buf == 1 and '?' or '&')
            insert(buf, urlencode(k))
            insert(buf, '=')
            insert(buf, urlencode(v))
        end
        url = concat(buf)
    end

    local req = {
        {'User-Agent', USER_AGENT},
        {'Authorization', self._token},
    }

    if API_VERSION < 8 then
        insert(req, {'X-RateLimit-Precision', PRECISION})
    end

    if payloadRequired[method] then
        payload = payload and encode(payload) or '{}'
        if files and next(files) then
            local boundary
            payload, boundary = attachFiles(payload, files)
            insert(req, {'Content-Type', MULTIPART .. boundary})
        else
            insert(req, {'Content-Type', JSON})
        end
        insert(req, {'Content-Length', #payload})
    end

    -- Pass the mutex to commit so it can release and re-acquire if needed (e.g., global rate limit)
    local data, err, api_delay, is_global_ratelimit = self:commit(method, url, req, payload, 0, mutex)

    -- Release the mutex immediately after the request completes or if a retry is handled internally by commit.
    -- If commit fully handled a global rate limit by sleeping and then retrying internally,
    -- the mutex would still be held when it returns, so we explicitly unlock here.
    mutex:unlock()

    -- Store the next reset time if provided by Discord for this route
    if api_delay then
        mutex._ratelimit_reset_after = uv.now() + api_delay
    end

    -- If the commit function indicated a global rate limit, update the global timestamp
    if is_global_ratelimit and api_delay then
        self._global_ratelimit_reset_after = uv.now() + api_delay
    end

    if data then
        return data
    else
        return nil, err
    end
end

function API:commit(method, url, req, payload, retries, mutex)
    local client = self._client
    local options = client._options

    local success, res, msg = pcall(request, method, url, req, payload)

    if not success then
        -- Network error, can't even make the request.
        -- Return a small delay to prevent immediate re-attempts without a pause.
        -- The mutex is still held here, but for network errors, we generally want to retry quickly.
        client:error(f("Network request failed: %s", res))
        if retries < options.maxRetries then
            local wait_time = options.routeDelay + random(2000) -- Add jitter
            client:warning(f("Retrying network request after %i ms", wait_time))
            sleep(wait_time / 1000)
            return self:commit(method, url, req, payload, retries + 1, mutex)
        else
            return nil, f("Network error after %i retries: %s", options.maxRetries, res), 0
        end
    end

    for i, v in ipairs(res) do
        res[v[1]:lower()] = v[2]
        res[i] = nil
    end

    local data = res['content-type'] and res['content-type']:find(JSON, 1, true) and decode(msg, 1, null) or msg
    local reset_after_ms = 0
    local is_global_ratelimit = false

    -- Discord can send X-RateLimit-Global for global rate limits
    if res['x-ratelimit-global'] == 'true' then
        is_global_ratelimit = true
    end

    -- Always prioritize X-RateLimit-Reset-After or retry_after
    if res['x-ratelimit-reset-after'] then
        reset_after_ms = max(reset_after_ms, 1000 * tonumber(res['x-ratelimit-reset-after']))
    end

    if res.code < 300 then
        client:debug('%i - %s : %s %s', res.code, res.reason, method, url)
        -- For successful requests, return the reset_after from headers
        return data, nil, reset_after_ms, is_global_ratelimit

    else
        -- Error handling
        if type(data) == 'table' then
            local retry = false
            if res.code == 429 then
                reset_after_ms = data.retry_after or 0 -- Discord returns this in ms already
                retry = retries < options.maxRetries
                is_global_ratelimit = data.global or false -- Check for global rate limit specifically
            elseif res.code >= 500 and res.code < 600 then -- 5xx server errors
                -- For 5xx errors, we calculate a delay for retry
                reset_after_ms = (options.routeDelay or 1000) * (2 ^ retries) + random(1000) -- Exponential backoff with jitter
                retry = retries < options.maxRetries
            end

            if retry then
                client:warning('%i - %s : retrying after %i ms : %s %s', res.code, res.reason, reset_after_ms, method, url)
                -- Release the mutex before sleeping for a retry, especially for 429s.
                -- Re-acquire it after the sleep and before the next commit attempt.
                if mutex then mutex:unlock() end
                sleep(reset_after_ms / 1000)
                if mutex then mutex:lock() end
                return self:commit(method, url, req, payload, retries + 1, mutex)
            end

            if data.code and data.message then
                msg = f('HTTP Error %i : %s', data.code, data.message)
            else
                msg = f('HTTP Error %i : %s', res.code, res.reason) -- Fallback if no specific Discord error
            end
            if data.errors then
                msg = parseErrors({msg}, data.errors)
            end
        else
            msg = f('HTTP Error %i : %s - %s', res.code, res.reason, msg)
        end

        client:error('%i - %s : %s %s', res.code, res.reason, method, url)
        if res.code == 400 then
            p("400 Bad Request", msg) -- Consider changing 'p' to client:error or similar
        end
        -- For failed requests, return the calculated delay and global flag
        return nil, msg, reset_after_ms, is_global_ratelimit
    end
end

-- start of auto-generated methods --

function API:getGuildAuditLog(guild_id, query)
    local endpoint = f(endpoints.GUILD_AUDIT_LOGS, guild_id)
    return self:request("GET", endpoint, nil, query)
end

function API:getChannel(channel_id) -- not exposed, use cache
    local endpoint = f(endpoints.CHANNEL, channel_id)
    return self:request("GET", endpoint)
end

function API:getChannelPermissionOverwrites(channel_id)
    local data, err = self:getChannel(channel_id)
    if data then
        return data.permission_overwrites or {}
    else
        return nil, err
    end
end

function API:modifyChannel(channel_id, payload) -- Channel:_modify
    local endpoint = f(endpoints.CHANNEL, channel_id)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteChannel(channel_id) -- Channel:delete
    local endpoint = f(endpoints.CHANNEL, channel_id)
    return self:request("DELETE", endpoint)
end

function API:getChannelMessages(channel_id, query) -- TextChannel:get[First|Last]Message, TextChannel:getMessages
    local endpoint = f(endpoints.CHANNEL_MESSAGES, channel_id)
    return self:request("GET", endpoint, nil, query)
end

function API:getChannelMessage(channel_id, message_id) -- TextChannel:getMessage fallback
    local endpoint = f(endpoints.CHANNEL_MESSAGE, channel_id, message_id)
    return self:request("GET", endpoint)
end

function API:createMessage(channel_id, payload, files) -- TextChannel:send
    local endpoint = f(endpoints.CHANNEL_MESSAGES, channel_id)
    return self:request("POST", endpoint, payload, nil, files)
end

function API:crosspostMessage(channel_id, message_id) -- Message:crosspost
    local endpoint = f(endpoints.CHANNEL_MESSAGE_CROSSPOST, channel_id, message_id)
    return self:request("POST", endpoint)
end

function API:createReaction(channel_id, message_id, emoji, payload) -- Message:addReaction
    local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION_ME, channel_id, message_id, urlencode(emoji))
    return self:request("PUT", endpoint, payload)
end

function API:deleteOwnReaction(channel_id, message_id, emoji) -- Message:removeReaction
    local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION_ME, channel_id, message_id, urlencode(emoji))
    return self:request("DELETE", endpoint)
end

function API:deleteUserReaction(channel_id, message_id, emoji, user_id) -- Message:removeReaction
    local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION_USER, channel_id, message_id, urlencode(emoji), user_id)
    return self:request("DELETE", endpoint)
end

function API:getReactions(channel_id, message_id, emoji, query) -- Reaction:getUsers
    local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTION, channel_id, message_id, urlencode(emoji))
    return self:request("GET", endpoint, nil, query)
end

function API:deleteAllReactions(channel_id, message_id) -- Message:clearReactions
    local endpoint = f(endpoints.CHANNEL_MESSAGE_REACTIONS, channel_id, message_id)
    return self:request("DELETE", endpoint)
end

function API:editMessage(channel_id, message_id, payload) -- Message:_modify
    local endpoint = f(endpoints.CHANNEL_MESSAGE, channel_id, message_id)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteMessage(channel_id, message_id) -- Message:delete
    local endpoint = f(endpoints.CHANNEL_MESSAGE, channel_id, message_id)
    return self:request("DELETE", endpoint)
end

function API:bulkDeleteMessages(channel_id, payload) -- GuildTextChannel:bulkDelete
    local endpoint = f(endpoints.CHANNEL_MESSAGES_BULK_DELETE, channel_id)
    return self:request("POST", endpoint, payload)
end

function API:editChannelPermissions(channel_id, overwrite_id, payload) -- various PermissionOverwrite methods
    local endpoint = f(endpoints.CHANNEL_PERMISSION, channel_id, overwrite_id)
    return self:request("PUT", endpoint, payload)
end

function API:getChannelInvites(channel_id) -- GuildChannel:getInvites
    local endpoint = f(endpoints.CHANNEL_INVITES, channel_id)
    return self:request("GET", endpoint)
end

function API:createChannelInvite(channel_id, payload) -- GuildChannel:createInvite
    local endpoint = f(endpoints.CHANNEL_INVITES, channel_id)
    return self:request("POST", endpoint, payload)
end

function API:deleteChannelPermission(channel_id, overwrite_id) -- PermissionOverwrite:delete
    local endpoint = f(endpoints.CHANNEL_PERMISSION, channel_id, overwrite_id)
    return self:request("DELETE", endpoint)
end

function API:followNewsChannel(channel_id, payload) -- GuildChannel:follow
    local endpoint = f(endpoints.CHANNEL_FOLLOWERS, channel_id)
    return self:request("POST", endpoint, payload)
end

function API:triggerTypingIndicator(channel_id, payload) -- TextChannel:broadcastTyping
    local endpoint = f(endpoints.CHANNEL_TYPING, channel_id)
    return self:request("POST", endpoint, payload)
end

function API:getPinnedMessages(channel_id) -- TextChannel:getPinnedMessages
    local endpoint = f(endpoints.CHANNEL_PINS, channel_id)
    return self:request("GET", endpoint)
end

function API:addPinnedChannelMessage(channel_id, message_id, payload) -- Message:pin
    local endpoint = f(endpoints.CHANNEL_PIN, channel_id, message_id)
    return self:request("PUT", endpoint, payload)
end

function API:deletePinnedChannelMessage(channel_id, message_id) -- Message:unpin
    local endpoint = f(endpoints.CHANNEL_PIN, channel_id, message_id)
    return self:request("DELETE", endpoint)
end

function API:groupDMAddRecipient(channel_id, user_id, payload) -- GroupChannel:addRecipient
    local endpoint = f(endpoints.CHANNEL_RECIPIENT, channel_id, user_id)
    return self:request("PUT", endpoint, payload)
end

function API:groupDMRemoveRecipient(channel_id, user_id) -- GroupChannel:removeRecipient
    local endpoint = f(endpoints.CHANNEL_RECIPIENT, channel_id, user_id)
    return self:request("DELETE", endpoint)
end

function API:listGuildEmojis(guild_id) -- not exposed, use cache
    local endpoint = f(endpoints.GUILD_EMOJIS, guild_id)
    return self:request("GET", endpoint)
end

function API:getGuildEmoji(guild_id, emoji_id) -- not exposed, use cache
    local endpoint = f(endpoints.GUILD_EMOJI, guild_id, emoji_id)
    return self:request("GET", endpoint)
end

function API:createGuildEmoji(guild_id, payload) -- Guild:createEmoji
    local endpoint = f(endpoints.GUILD_EMOJIS, guild_id)
    return self:request("POST", endpoint, payload)
end

function API:modifyGuildEmoji(guild_id, emoji_id, payload) -- Emoji:_modify
    local endpoint = f(endpoints.GUILD_EMOJI, guild_id, emoji_id)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteGuildEmoji(guild_id, emoji_id) -- Emoji:delete
    local endpoint = f(endpoints.GUILD_EMOJI, guild_id, emoji_id)
    return self:request("DELETE", endpoint)
end

function API:createGuildSticker(guild_id, payload) -- Guild:createSticker
    local endpoint = f(endpoints.GUILD_STICKERS, guild_id)
    return self:request("POST", endpoint, payload, nil, {{ "sticker.png", payload.image}})
end

function API:getGuildStickers(guild_id) -- not exposed, use cache
    local endpoint = f(endpoints.GUILD_STICKERS, guild_id)
    return self:request("GET", endpoint)
end

function API:getGuildSticker(guild_id, sticker_id) -- Guild:getSticker
    local endpoint = f(endpoints.GUILD_STICKER, guild_id, sticker_id)
    return self:request("GET", endpoint)
end

function API:modifyGuildSticker(guild_id, sticker_id, payload) -- Sticker:_modify
    local endpoint = f(endpoints.GUILD_STICKER, guild_id, sticker_id)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteGuildSticker(guild_id, sticker_id) -- Sticker:delete
    local endpoint = f(endpoints.GUILD_STICKER, guild_id, sticker_id)
    return self:request("DELETE", endpoint)
end

function API:createGuild(payload) -- Client:createGuild
    local endpoint = endpoints.GUILDS
    return self:request("POST", endpoint, payload)
end

function API:getGuild(guild_id) -- not exposed, use cache
    local endpoint = f(endpoints.GUILD, guild_id)
    return self:request("GET", endpoint)
end

function API:modifyGuild(guild_id, payload) -- Guild:_modify
    local endpoint = f(endpoints.GUILD, guild_id)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteGuild(guild_id) -- Guild:delete
    local endpoint = f(endpoints.GUILD, guild_id)
    return self:request("DELETE", endpoint)
end

function API:getGuildChannels(guild_id) -- not exposed, use cache
    local endpoint = f(endpoints.GUILD_CHANNELS, guild_id)
    return self:request("GET", endpoint)
end

function API:createGuildChannel(guild_id, payload) -- Guild:create[Text|Voice]Channel
    local endpoint = f(endpoints.GUILD_CHANNELS, guild_id)
    return self:request("POST", endpoint, payload)
end

function API:modifyGuildChannelPositions(guild_id, payload) -- GuildChannel:move[Up|Down]
    local endpoint = f(endpoints.GUILD_CHANNELS, guild_id)
    return self:request("PATCH", endpoint, payload)
end

function API:getGuildMember(guild_id, user_id) -- Guild:getMember fallback
    local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
    return self:request("GET", endpoint)
end

function API:listGuildMembers(guild_id) -- not exposed, use cache
    local endpoint = f(endpoints.GUILD_MEMBERS, guild_id)
    return self:request("GET", endpoint)
end

function API:addGuildMember(guild_id, user_id, payload) -- not exposed, limited use
    local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
    return self:request("PUT", endpoint, payload)
end

function API:modifyGuildMember(guild_id, user_id, payload) -- various Member methods
    local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
    return self:request("PATCH", endpoint, payload)
end

function API:modifyCurrentUsersNick(guild_id, payload) -- Member:setNickname
    local endpoint = f(endpoints.GUILD_MEMBER_ME_NICK, guild_id)
    return self:request("PATCH", endpoint, payload)
end

function API:addGuildMemberRole(guild_id, user_id, role_id, payload) -- Member:addrole
    local endpoint = f(endpoints.GUILD_MEMBER_ROLE, guild_id, user_id, role_id)
    return self:request("PUT", endpoint, payload)
end

function API:removeGuildMemberRole(guild_id, user_id, role_id) -- Member:removeRole
    local endpoint = f(endpoints.GUILD_MEMBER_ROLE, guild_id, user_id, role_id)
    return self:request("DELETE", endpoint)
end

function API:removeGuildMember(guild_id, user_id, query) -- Guild:kickUser
    local endpoint = f(endpoints.GUILD_MEMBER, guild_id, user_id)
    return self:request("DELETE", endpoint, nil, query)
end

function API:getGuildBans(guild_id) -- Guild:getBans
    local endpoint = f(endpoints.GUILD_BANS, guild_id)
    return self:request("GET", endpoint)
end

function API:getGuildBan(guild_id, user_id) -- Guild:getBan
    local endpoint = f(endpoints.GUILD_BAN, guild_id, user_id)
    return self:request("GET", endpoint)
end

function API:createGuildBan(guild_id, user_id, query) -- Guild:banUser
    local endpoint = f(endpoints.GUILD_BAN, guild_id, user_id)
    return self:request("PUT", endpoint, nil, query)
end

function API:removeGuildBan(guild_id, user_id, query) -- Guild:unbanUser / Ban:delete
    local endpoint = f(endpoints.GUILD_BAN, guild_id, user_id)
    return self:request("DELETE", endpoint, nil, query)
end

function API:getGuildRoles(guild_id) -- not exposed, use cache
    local endpoint = f(endpoints.GUILD_ROLES, guild_id)
    return self:request("GET", endpoint)
end

function API:createGuildRole(guild_id, payload) -- Guild:createRole
    local endpoint = f(endpoints.GUILD_ROLES, guild_id)
    return self:request("POST", endpoint, payload)
end

function API:modifyGuildRolePositions(guild_id, payload) -- Role:move[Up|Down]
    local endpoint = f(endpoints.GUILD_ROLES, guild_id)
    return self:request("PATCH", endpoint, payload)
end

function API:modifyGuildRole(guild_id, role_id, payload) -- Role:_modify
    local endpoint = f(endpoints.GUILD_ROLE, guild_id, role_id)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteGuildRole(guild_id, role_id) -- Role:delete
    local endpoint = f(endpoints.GUILD_ROLE, guild_id, role_id)
    return self:request("DELETE", endpoint)
end

function API:getGuildPruneCount(guild_id, query) -- Guild:getPruneCount
    local endpoint = f(endpoints.GUILD_PRUNE, guild_id)
    return self:request("GET", endpoint, nil, query)
end

function API:beginGuildPrune(guild_id, payload, query) -- Guild:pruneMembers
    local endpoint = f(endpoints.GUILD_PRUNE, guild_id)
    return self:request("POST", endpoint, payload, query)
end

function API:getGuildVoiceRegions(guild_id) -- Guild:listVoiceRegions
    local endpoint = f(endpoints.GUILD_REGIONS, guild_id)
    return self:request("GET", endpoint)
end

function API:getGuildInvites(guild_id) -- Guild:getInvites
    local endpoint = f(endpoints.GUILD_INVITES, guild_id)
    return self:request("GET", endpoint)
end

function API:getGuildIntegrations(guild_id) -- not exposed, maybe in the future
    local endpoint = f(endpoints.GUILD_INTEGRATIONS, guild_id)
    return self:request("GET", endpoint)
end

function API:createGuildIntegration(guild_id, payload) -- not exposed, maybe in the future
    local endpoint = f(endpoints.GUILD_INTEGRATIONS, guild_id)
    return self:request("POST", endpoint, payload)
end

function API:modifyGuildIntegration(guild_id, integration_id, payload) -- not exposed, maybe in the future
    local endpoint = f(endpoints.GUILD_INTEGRATION, guild_id, integration_id)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteGuildIntegration(guild_id, integration_id) -- not exposed, maybe in the future
    local endpoint = f(endpoints.GUILD_INTEGRATION, guild_id, integration_id)
    return self:request("DELETE", endpoint)
end

function API:syncGuildIntegration(guild_id, integration_id, payload) -- not exposed, maybe in the future
    local endpoint = f(endpoints.GUILD_INTEGRATION_SYNC, guild_id, integration_id)
    return self:request("POST", endpoint, payload)
end

function API:getGuildEmbed(guild_id) -- not exposed, maybe in the future
    local endpoint = f(endpoints.GUILD_EMBED, guild_id)
    return self:request("GET", endpoint)
end

function API:modifyGuildEmbed(guild_id, payload) -- not exposed, maybe in the future
    local endpoint = f(endpoints.GUILD_EMBED, guild_id)
    return self:request("PATCH", endpoint, payload)
end

function API:getInvite(invite_code, query) -- Client:getInvite
    local endpoint = f(endpoints.INVITE, invite_code)
    return self:request("GET", endpoint, nil, query)
end

function API:deleteInvite(invite_code) -- Invite:delete
    local endpoint = f(endpoints.INVITE, invite_code)
    return self:request("DELETE", endpoint)
end

function API:acceptInvite(invite_code, payload) -- not exposed, invalidates tokens
    local endpoint = f(endpoints.INVITE, invite_code)
    return self:request("POST", endpoint, payload)
end

function API:getCurrentUser() -- API:authenticate
    local endpoint = endpoints.USER_ME
    return self:request("GET", endpoint)
end

function API:getUser(user_id) -- Client:getUser
    local endpoint = f(endpoints.USER, user_id)
    return self:request("GET", endpoint)
end

function API:modifyCurrentUser(payload) -- Client:_modify
    local endpoint = endpoints.USER_ME
    return self:request("PATCH", endpoint, payload)
end

function API:getCurrentUserGuilds() -- not exposed, use cache
    local endpoint = endpoints.USER_ME_GUILDS
    return self:request("GET", endpoint)
end

function API:leaveGuild(guild_id) -- Guild:leave
    local endpoint = f(endpoints.USER_ME_GUILD, guild_id)
    return self:request("DELETE", endpoint)
end

function API:getUserDMs() -- not exposed, use cache
    local endpoint = endpoints.USER_ME_CHANNELS
    return self:request("GET", endpoint)
end

function API:createDM(payload) -- User:getPrivateChannel fallback
    local endpoint = endpoints.USER_ME_CHANNELS
    return self:request("POST", endpoint, payload)
end

function API:createGroupDM(payload) -- Client:createGroupChannel
    local endpoint = endpoints.USER_ME_CHANNELS
    return self:request("POST", endpoint, payload)
end

function API:getUsersConnections() -- Client:getConnections
    local endpoint = endpoints.USER_ME_CONNECTIONS
    return self:request("GET", endpoint)
end

function API:listVoiceRegions() -- Client:listVoiceRegions
    local endpoint = endpoints.VOICE_REGIONS
    return self:request("GET", endpoint)
end

function API:createWebhook(channel_id, payload) -- GuildTextChannel:createWebhook
    local endpoint = f(endpoints.CHANNEL_WEBHOOKS, channel_id)
    return self:request("POST", endpoint, payload)
end

function API:getChannelWebhooks(channel_id) -- GuildTextChannel:getWebhooks
    local endpoint = f(endpoints.CHANNEL_WEBHOOKS, channel_id)
    return self:request("GET", endpoint)
end

function API:getGuildWebhooks(guild_id) -- Guild:getWebhooks
    local endpoint = f(endpoints.GUILD_WEBHOOKS, guild_id)
    return self:request("GET", endpoint)
end

function API:getWebhook(webhook_id) -- Client:getWebhook
    local endpoint = f(endpoints.WEBHOOK, webhook_id)
    return self:request("GET", endpoint)
end

function API:getWebhookWithToken(webhook_id, webhook_token) -- not exposed, needs webhook client
    local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
    return self:request("GET", endpoint)
end

function API:modifyWebhook(webhook_id, payload) -- Webhook:_modify
    local endpoint = f(endpoints.WEBHOOK, webhook_id)
    return self:request("PATCH", endpoint, payload)
end

function API:modifyWebhookWithToken(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
    local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
    return self:request("PATCH", endpoint, payload)
end

function API:deleteWebhook(webhook_id) -- Webhook:delete
    local endpoint = f(endpoints.WEBHOOK, webhook_id)
    return self:request("DELETE", endpoint)
end

function API:deleteWebhookWithToken(webhook_id, webhook_token) -- not exposed, needs webhook client
    local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
    return self:request("DELETE", endpoint)
end

function API:executeWebhook(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
    local endpoint = f(endpoints.WEBHOOK_TOKEN, webhook_id, webhook_token)
    return self:request("POST", endpoint, payload)
end

function API:executeSlackCompatibleWebhook(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
    local endpoint = f(endpoints.WEBHOOK_TOKEN_SLACK, webhook_id, webhook_token)
    return self:request("POST", endpoint, payload)
end

function API:executeGitHubCompatibleWebhook(webhook_id, webhook_token, payload) -- not exposed, needs webhook client
    local endpoint = f(endpoints.WEBHOOK_TOKEN_GITHUB, webhook_id, webhook_token)
    return self:request("POST", endpoint, payload)
end

function API:getGateway() -- Client:run
    local endpoint = endpoints.GATEWAY
    return self:request("GET", endpoint)
end

function API:getGatewayBot() -- Client:run
    local endpoint = endpoints.GATEWAY_BOT
    return self:request("GET", endpoint)
end

function API:getCurrentApplicationInformation() -- Client:run
    local endpoint = endpoints.OAUTH2_APPLICATION_ME
    return self:request("GET", endpoint)
end

function API:getThreadMember(channel_id, user_id)
    local endpoint = f(endpoints.THREAD_MEMBER, channel_id, user_id)
    return self:request("GET", endpoint)
end

function API:getThreadMembers(channel_id, query)
    local endpoint = f(endpoints.THREAD_MEMBERS, channel_id)
    return self:request("GET", endpoint, nil, query)
end

function API:addThreadMember(channel_id, user_id)
    local endpoint = f(endpoints.THREAD_MEMBER, channel_id, user_id)
    return self:request("PUT", endpoint)
end

function API:removeThreadMember(channel_id, user_id)
    local endpoint = f(endpoints.THREAD_MEMBER, channel_id, user_id)
    return self:request("DELETE", endpoint)
end

function API:getCurrentThreadMember(channel_id)
    local endpoint = f(endpoints.THREAD_MEMBER, channel_id)
    return self:request("GET", endpoint)
end

function API:joinThread(channel_id)
    local endpoint = f(endpoints.THREAD_MEMBER_ME, channel_id)
    return self:request("PUT", endpoint)
end

function API:leaveThread(channel_id)
    local endpoint = f(endpoints.THREAD_MEMBER_ME, channel_id)
    return self:request("DELETE", endpoint)
end

function API:startThreadWithMessage(channel_id, message_id, payload)
    local endpoint = f(endpoints.THREAD_START, channel_id, message_id)
    return self:request("POST", endpoint, payload)
end

function API:startThreadWithoutMessage(channel_id, payload)
    local endpoint = f(endpoints.THREAD_START_WITHOUT_MESSAGE, channel_id)
    return self:request("POST", endpoint, payload)
end

function API:listArchivedPublicThreads(channel_id, query)
    local endpoint = f(endpoints.THREAD_ARCHIVED, channel_id)
    return self:request("GET", endpoint, nil, query)
end

function API:listArchivedPrivateThreads(channel_id, query)
    local endpoint = f(endpoints.THREAD_ARCHIVED_PRIVATE, channel_id)
    return self:request("GET", endpoint, nil, query)
end

function API:listJoinedArchivedPrivateThreads(channel_id, query)
    local endpoint = f(endpoints.THREAD_JOINED_ARCHIVED_PRIVATE, channel_id)
    return self:request("GET", endpoint, nil, query)
end

function API:getForumTag(channel_id, tag_id)
    local endpoint = f(endpoints.CHANNEL_TAG, channel_id, tag_id)
    return self:request("GET", endpoint)
end

function API:createForumTag(channel_id, payload)
    local endpoint = f(endpoints.CHANNEL_TAGS, channel_id)
    return self:request("POST", endpoint, payload)
end

function API:modifyForumTag(channel_id, tag_id, payload)
    local endpoint = f(endpoints.CHANNEL_TAG, channel_id, tag_id)
    return self:request("PUT", endpoint, payload)
end

function API:deleteForumTag(channel_id, tag_id)
    local endpoint = f(endpoints.CHANNEL_TAG, channel_id, tag_id)
    return self:request("DELETE", endpoint)
end

-- end of auto-generated methods --

return API
