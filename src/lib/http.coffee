###

dnschain
http://dnschain.net

Copyright (c) 2014 okTurtles Foundation

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

###

express = require 'express'

module.exports = (dnschain) ->
    # expose these into our namespace
    for k of dnschain.globals
        eval "var #{k} = dnschain.globals.#{k};"

    class HTTPServer
        constructor: (@dnschain) ->
            @log = gNewLogger 'HTTP'
            @log.debug "Loading HTTPServer..."
            @rateLimiting = gConf.get 'rateLimiting:http'
            app = express()

            # Openname spec defined here:
            # - https://github.com/okTurtles/openname-specifications/blob/resolvers/resolvers.md
            # - https://github.com/openname/openname-specifications/blob/master/resolvers.md
            
            opennameRoute = express.Router()
            
            # Resolver specific API
            opennameRoute.get /\/(?:resolver|dnschain)\/([^\/\.]+)(?:\.([a-z]+))?/, (req, res) =>
                @log.debug gLineInfo("resolver API called"), {params: req.params}
                [resource, format] = req.params
                if resource == "fingerprint"
                    if !format or format is 'json'
                        res.json {fingerprint: @dnschain.encryptedserver.getFingerprint()}
                    else
                        @sendErr req, res, 400, "Unsupported format: #{format}"
                else
                    @sendErr req, res, 400, "Bad resource: #{resource}"

            # Datastore API
            opennameRoute.route(/// ^
                \/(\w+)     # the datastore name
                \/(\w+)     # the corresponding resource
                (?:
                    \/  ([^\/\.]+)    # optional property (or action on resource) 
                    (?:
                        \/ ([^\/\.]+) # optional action on property
                    )?
                )?
                (?:\.([a-z]+))?     # optional response format
                $ ///
            ).get (req, res) =>
                @log.debug gLineInfo("get v1"), {params: req.params}
                [datastore, resource, propOrAction, action, fmt] = req.params

                if not (resolver = @dnschain.chains[datastore])
                    return @sendErr req, res, 400, "Unsupported datastore: #{datastore}"

                if not resolver.resources[resource]
                    return @sendErr req, res, 400, "Unsupported resource: #{resource}"

                @dnschain.cache.resolveResource resolver, resource, propOrAction, action, fmt, req.query, @postResolveCallback(req, res, propOrAction)
            
            opennameRoute.use (req, res) =>
                @sendErr req, res, 400, "Bad v1 request"

            app.use "/v1", opennameRoute
            app.get "*", @callback.bind(@) # Old, deprecated API usage.

            app.use (err, req, res, next) =>
                @log.warn gLineInfo('error handler triggered'),
                    errMessage: err?.message
                    stack: err?.stack
                    req: _.at(req, ['originalUrl','ip','ips','protocol','hostname','headers'])
                res.status(500).send "Internal Error: #{err?.message}"

            @server = http.createServer (req, res) =>
                key = "http-#{req.connection?.remoteAddress}"
                @log.debug gLineInfo("creating bottleneck on: #{key}")
                limiter = gThrottle key, => new Bottleneck _.at(@rateLimiting, ['maxConcurrent','minTime','highWater','strategy'])...

                # Since Express doesn't take a callback function
                # we capture the callback that Bottleneck requires
                # in `bottleCB` and call it by hooking into `res.end`
                savedEnd = res.end.bind(res)
                bottleCB = null
                res.end = (args...) =>
                    savedEnd args...
                    bottleCB()

                limiter.submit (cb) ->
                    bottleCB = cb
                    app req, res
                , null
            
            gErr("http create") unless @server
                
            @server.on 'error', (err) -> gErr err
            gFillWithRunningChecks @

        start: ->
            @startCheck (cb) =>
                @server.listen gConf.get('http:port'), gConf.get('http:host'), =>
                    cb null, gConf.get 'http'

        shutdown: ->
            @shutdownCheck (cb) =>
                @log.debug 'shutting down!'
                @server.close cb

        # TODO: move/rename this function + indicate it's deprecated usage
        callback: (req, res) ->
            path = S(url.parse(req.originalUrl).pathname).chompLeft('/').s
            options = url.parse(req.originalUrl, true).query
            @log.debug gLineInfo('request'), {path:path, options:options, url:req.originalUrl}

            [...,resolverName] =
                if S(header = req.headers.blockchain || req.headers.host).endsWith('.dns')
                    S(header).chompRight('.dns').s.split('.')
                else
                    ['none']

            if not (resolver = @dnschain.chains[resolverName])
                @log.warn gLineInfo('unknown blockchain'), {host: req.headers.host, blockchainHeader: req.headers.blockchain, remoteAddress: req.connection.remoteAddress}
                return @sendErr req, res, 400, "Unsupported blockchain: #{resolverName}"

            if not resolver.validRequest path
                @log.debug gLineInfo("invalid request: #{path}")
                return @sendErr req, res, 400, "Bad request: #{path}"

            @dnschain.cache.resolveBlockchain resolver, path, options, @postResolveCallback(req, res, path)

        sendErr: (req, res, code=404, comment="Not Found") =>
            @log.warn gLineInfo('notFound'),
                comment: comment
                code: code
                req: _.at(req, ['originalUrl','protocol','hostname'])
            res.status(code).send comment

        postResolveCallback: (req, res, item) =>
            (err,result) =>
                if err
                    @log.debug gLineInfo('resolver failed'), {err:err.message}
                    @sendErr req, res, 404, "Not Found: #{item}"
                else
                    @log.debug gLineInfo('postResolve'), {path:item, result:result}
                    res.json result
