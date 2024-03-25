/*
Copyright (c) 2023-2024 Andrea Fontana

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
*/

module serverino.worker;

import serverino.common;
import serverino.config;
import serverino.interfaces;
import std.experimental.logger : log, warning, info, fatal, critical;
import std.process : environment;
import std.stdio : FILE;
import std.socket;
import std.datetime : seconds;
import std.string : toStringz, indexOf, strip, toLower, empty;
import std.algorithm : splitter, startsWith, map;
import std.range : assumeSorted;
import std.format : format;
import std.conv : to;
import core.atomic : cas, atomicLoad, atomicStore;

extern(C) int dup(int a);
extern(C) int dup2(int a, int b);
extern(C) int fileno(FILE *stream);


struct Worker
{
   static auto instance()
   {
      static Worker* _instance;
      if (_instance is null) _instance = new Worker();
      return _instance;
   }

   void wake(Modules...)(WorkerConfigPtr config)
   {
      import std.conv : to;
      import std.stdio;
      import std.format : format;

      isDynamic = environment.get("SERVERINO_DYNAMIC_WORKER") == "1";
      daemonProcess = new ProcessInfo(environment.get("SERVERINO_DAEMON").to!int);

      version(linux) char[] socketAddress = char(0) ~ cast(char[])environment.get("SERVERINO_SOCKET");
      else
      {
         import std.path : buildPath;
         import std.file : tempDir;
         char[] socketAddress = cast(char[]) environment.get("SERVERINO_SOCKET");
      }

      assert(socketAddress.length > 0);

      channel = new Socket(AddressFamily.UNIX, SocketType.STREAM);
      channel.connect(new UnixAddress(socketAddress));
      channel.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 1.seconds);

      ubyte[1] ack = ['\0'];
      channel.send(ack);

      request._internal = new Request.RequestImpl();
      output._internal = new Output.OutputImpl();

      version(Windows)
      {
         log("Worker started.");
      }
      else
      {
         import core.sys.posix.pwd;
         import core.sys.posix.grp;
         import core.sys.posix.unistd;
         import core.stdc.string : strlen;

         if (config.group.length > 0)
         {
            auto gi = getgrnam(config.group.toStringz);
            if (gi !is null) setgid(gi.gr_gid);
            else fatal("Can't find group ", config.group);
         }

         if (config.user.length > 0)
         {
            auto ui = getpwnam(config.user.toStringz);
            if (ui !is null) setuid(ui.pw_uid);
            else fatal("Can't find user ", config.user);
         }

         auto ui = getpwuid(getuid());
         auto gr = getgrgid(getgid());

         if (ui.pw_uid == 0) critical("Worker running as root. Is this intended? Set user/group from config to run worker as unprivileged user.");
         else log("Worker started. (user=", ui.pw_name[0..ui.pw_name.strlen], " group=", gr.gr_name[0..gr.gr_name.strlen], ")");

      }

      // Prevent read from stdin
      {
         import std.stdio : stdin;

         version(Windows)  auto nullSink = fopen("NUL", "r");
         version(Posix)    auto nullSink = fopen("/dev/null", "r");

         dup2(fileno(nullSink), fileno(stdin.getFP));
      }

      tryInit!Modules();

      import std.string : chomp;

      import core.thread : Thread;
      import core.stdc.stdlib : exit;
      __gshared bool justSent = false;

      new Thread({

         Thread.getThis().isDaemon = true;
         Thread.getThis().priority = Thread.PRIORITY_MIN;

         while(true)
         {
            Thread.yield();

            CoarseTime st = atomicLoad(processedStartedAt);

            if (!(st == CoarseTime.zero || CoarseTime.currTime - st < config.maxRequestTime))
               break;

            Thread.sleep(1.seconds);
         }

         log("Request timeout.");

         if (cas(&justSent, false, true))
         {
            WorkerPayload wp;

            output._internal.clear();
            output.status = 504;
            output._internal.buildHeaders();
            wp.isKeepAlive = false;
            atomicStore(processedStartedAt, CoarseTime.zero);
            wp.contentLength = output._internal._headersBuffer.array.length + output._internal._sendBuffer.array.length;

            channel.send((cast(char*)&wp)[0..wp.sizeof] ~ output._internal._headersBuffer.array ~ output._internal._sendBuffer.array);
         }

         channel.close();
         exit(0);
      }).start();

      startedAt = CoarseTime.currTime;
      while(true)
      {
         import std.string : chomp;

         justSent = false;
         output._internal.clear();
         request._internal.clear();

         ubyte[32*1024] buffer;

         idlingAt = CoarseTime.currTime;

         import serverino.databuffer;

         uint size;
         bool sizeRead = false;
         ptrdiff_t recv = -1;
         static DataBuffer!ubyte data;
         data.clear();

         while(sizeRead == false || size > data.length)
         {
            recv = -1;
            while(recv == -1)
            {
               recv = channel.receive(buffer);
               import core.stdc.stdlib : exit;

               if (recv == -1)
               {

                  immutable tm = CoarseTime.currTime;
                  if (tm - idlingAt > config.maxWorkerIdling)
                  {
                     log("Killing worker. [REASON: maxWorkerIdling]");
                     tryUninit!Modules();
                     channel.close();
                     exit(0);
                  }
                  else if (tm - startedAt > config.maxWorkerLifetime)
                  {
                     log("Killing worker. [REASON: maxWorkerLifetime]");
                     tryUninit!Modules();
                     channel.close();
                     exit(0);
                  }
                  else if (isDynamic && tm - idlingAt > config.maxDynamicWorkerIdling)
                  {
                     log("Killing worker. [REASON: cooling down]");
                     tryUninit!Modules();
                     channel.close();
                     exit(0);
                  }

                  continue;
               }
               else if (recv < 0)
               {
                  tryUninit!Modules();
                  log("Killing worker. [REASON: socket error]");
                  channel.close();
                  exit(cast(int)recv);
               }
            }

            if (recv == 0) break;
            else if (sizeRead == false)
            {
               size = *(cast(uint*)(buffer[0..uint.sizeof].ptr));
               data.reserve(size);
               data.append(buffer[uint.sizeof..recv]);
               sizeRead = true;
            }
            else data.append(buffer[0..recv]);
         }

         if(data.array.length == 0)
         {
            tryUninit!Modules();

            if (daemonProcess.isTerminated()) log("Killing worker. [REASON: daemon dead?]");
            else log("Killing worker. [REASON: socket closed?]");

            channel.close();
            exit(0);
         }

         ++requestId;

         WorkerPayload wp;
         wp.isKeepAlive = parseHttpRequest!Modules(config, data.array);
         wp.contentLength = output._internal._sendBuffer.array.length + output._internal._headersBuffer.array.length;

         if (cas(&justSent, false, true))
            channel.send((cast(char*)&wp)[0..wp.sizeof] ~  output._internal._headersBuffer.array ~ output._internal._sendBuffer.array);
      }


   }

   bool parseHttpRequest(Modules...)(WorkerConfigPtr config, ubyte[] data)
   {

      scope(exit) {
         output._internal.buildHeaders();
         if (!output._internal._sendBody)
            output._internal._sendBuffer.clear();
      }

      import std.utf : UTFException;

      version(debugRequest) log("-- START RECEIVING");
      try
      {
         size_t			   contentLength = 0;

         char[]			method;
         char[]			path;
         char[]			httpVersion;

         char[]			requestLine;
         char[]			headers;

         bool 			hasContentLength = false;


         headers = cast(char[]) data;
         auto headersEnd = headers.indexOf("\r\n\r\n");

         bool valid = true;

         // Headers completed?
         if (headersEnd > 0)
         {
            version(debugRequest) log("-- HEADERS COMPLETED");

            headers.length = headersEnd;
            data = data[headersEnd+4..$];

            auto headersLines = headers.splitter("\r\n");

            requestLine = headersLines.front;

            {
               auto fields = requestLine.splitter(' ');

               method = fields.front;
               fields.popFront;
               path = fields.front;
               fields.popFront;
               httpVersion = fields.front;

               if (["CONNECT", "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE"].assumeSorted.contains(method) == false)
               {
                  debug warning("HTTP method unknown: ", method);
                  valid = false;
               }
            }

            if (!valid)
            {
               output._internal._httpVersion = (httpVersion == "HTTP/1.1")?HttpVersion.HTTP11:HttpVersion.HTTP10;
               output._internal._sendBody = false;
               output.status = 400;
               return false;
            }

            headersLines.popFront;

            foreach(const ref l; headersLines)
            {
               auto firstColon = l.indexOf(':');
               if (firstColon > 0)

               if(l[0..firstColon] == "content-length")
               {
                  contentLength = l[firstColon+1..$].to!size_t;
                  hasContentLength = true;
                  break;
               }
            }

            // If no content-length, we don't read body.
            if (contentLength == 0)
            {
               version(debugRequest) log("-- NO CONTENT LENGTH, SKIP DATA");
               data.length = 0;
            }

            else if (data.length >= contentLength)
            {
               version(debugRequest) log("-- DATA ALREADY READ.");
               data.length = contentLength;
            }
         }
         else return false;

         version(debugRequest) log("-- PARSING DATA");

         {
            import std.algorithm : max;
            import std.uni : sicmp;

            request._internal._httpVersion    = (httpVersion == "HTTP/1.1")?(HttpVersion.HTTP11):(HttpVersion.HTTP10);
            request._internal._data           = cast(char[])data;
            request._internal._rawHeaders     = headers.to!string;
            request._internal._rawRequestLine = requestLine.to!string;

            output._internal._httpVersion = request._internal._httpVersion;

            bool insidePath = true;
            size_t pathLen = 0;
            size_t queryStart = 0;
            size_t queryLen = 0;

            foreach(i, const x; path)
            {
               if (insidePath)
               {
                  if (x == '?')
                  {
                     pathLen = i;
                     queryStart = i+1;
                     insidePath = false;
                  }
                  else if (x == '#')
                  {
                     pathLen = i;
                     break;
                  }
               }
               else
               {
                  // Should not happen!
                  if (x == '#')
                  {
                     queryLen = i;
                     break;
                  }
               }
            }

            if (pathLen == 0)
            {
               pathLen = path.length;
               queryStart = path.length;
               queryLen = path.length;
            }
            else if (queryLen == 0) queryLen = path.length;

            // Just to prevent uri attack like
            // GET /../../non_public_file
            auto normalize(string uri)
            {
               import std.range : retro, join;
               import std.algorithm : filter;
               import std.array : array;
               import std.typecons : tuple;
               size_t skips = 0;
               string norm = uri
                  .splitter('/')
                  .retro
                  .map!(
                        (x)
                        {
                           if (x == "..") skips++;
                           else if(x != ".")
                           {
                              if (skips == 0) return tuple(x, true);
                              else skips--;
                           }

                           return tuple(x, false);
                        }
                  )
                  .filter!(x => x[1] == true)
                  .map!(x => x[0])
                  .array
                  .retro
                  .join('/');

                  if (norm.startsWith("/")) return norm;
                  else return "/" ~ norm;
            }

            request._internal._uri            = normalize(cast(string)path[0..pathLen]);
            request._internal._rawQueryString = cast(string)path[queryStart..queryLen];
            request._internal._method         = method.to!string;

            output._internal._sendBody = (!["CONNECT", "HEAD", "TRACE"].assumeSorted.contains(request._internal._method));

            import std.uri : URIException;
            try { request._internal.process(); }
            catch (URIException e)
            {
               output.status = 400;
               output._internal._sendBody = false;
               return false;
            }

            output._internal._keepAlive =
               config.keepAlive &&
               output._internal._httpVersion == HttpVersion.HTTP11 &&
               sicmp(request.header.read("connection", "keep-alive"), "keep-alive") == 0;

            version(debugRequest)
            {
               log("-- REQ: ", request.uri);
               log("-- PARSING STATUS: ", request._internal._parsingStatus);

               try { log("-- REQ: ", request); }
               catch (Exception e ) {log("EX:", e);}
            }

            if (request._internal._parsingStatus == Request.ParsingStatus.OK)
            {
               try
               {
                  {
                     scope(exit) atomicStore(processedStartedAt, CoarseTime.zero);

                     atomicStore(processedStartedAt, CoarseTime.currTime);
                     callHandlers!Modules(request, output);
                  }

                  if (!output._internal._dirty)
                  {
                     output.status = 404;
                     output._internal._sendBody = false;
                  }

                  return (output._internal._keepAlive);

               }

               // Unhandled Exception escaped from user code
               catch (Exception e)
               {
                  critical(format("%s:%s Uncatched exception: %s", e.file, e.line, e.msg));
                  critical(format("-------\n%s",e.info));

                  output.status = 500;
                  return (output._internal._keepAlive);
               }

               // Even worse.
               catch (Throwable t)
               {
                  critical(format("%s:%s Throwable: %s", t.file, t.line, t.msg));
                  critical(format("-------\n%s",t.info));

                  // Rethrow
                  throw t;
               }
            }
            else
            {
               debug warning("Parsing error:", request._internal._parsingStatus);

               if (request._internal._parsingStatus == Request.ParsingStatus.InvalidBody) output.status = 422;
               else output.status = 400;

               output._internal._sendBody = false;
               return (output._internal._keepAlive);
            }

         }
      }
      catch(UTFException e)
      {
         output.status = 400;
         output._internal._sendBody = false;

         debug warning("UTFException: ", e.toString);
      }
      catch(Exception e) {

         output.status = 500;
         output._internal._sendBody = false;

         debug critical("Unhandled exception: ", e.toString);
      }

      return false;
   }

   void callHandlers(modules...)(Request request, Output output)
   {
      import std.algorithm : sort;
      import std.array : array;
      import std.traits : getUDAs, ParameterStorageClass, ParameterStorageClassTuple, fullyQualifiedName, getSymbolsByUDA;

      struct FunctionPriority
      {
         string   name;
         long     priority;
         string   mod;
      }

      auto getUntaggedHandlers()
      {
         FunctionPriority[] fps;
         static foreach(m; modules)
         {{
            alias globalNs = m;

            foreach(sy; __traits(allMembers, globalNs))
            {
               alias s = __traits(getMember, globalNs, sy);
               static if
               (
                  (
                     __traits(compiles, s(request, output)) ||
                     __traits(compiles, s(request)) ||
                     __traits(compiles, s(output))
                  )
               )
               {


                  static foreach(p; ParameterStorageClassTuple!s)
                  {
                     static if (p == ParameterStorageClass.ref_)
                     {
                        static if(!is(typeof(ValidSTC)))
                           enum ValidSTC = false;
                     }
                  }

                  static if(!is(typeof(ValidSTC)))
                     enum ValidSTC = true;


                  static if (ValidSTC)
                  {
                     FunctionPriority fp;
                     fp.name = __traits(identifier,s);
                     fp.priority = 0;
                     fp.mod = fullyQualifiedName!m;

                     fps ~= fp;
                  }
               }
            }
         }}

         return fps.sort!((a,b) => a.priority > b.priority).array;
      }

      auto getTaggedHandlers()
      {
         FunctionPriority[] fps;

         static foreach(m; modules)
         {{
            alias globalNs = m;

            foreach(s; getSymbolsByUDA!(globalNs, endpoint))
            {
               static if
               (
                  !__traits(compiles, s(request, output)) &&
                  !__traits(compiles, s(request)) &&
                  !__traits(compiles, s(output))
               )
               {
                  static assert(0, fullyQualifiedName!s ~ " is not a valid endpoint. Wrong params. Try to change its signature to `" ~ __traits(identifier,s) ~ "(Request request, Output output)`.");
               }

               static foreach(p; ParameterStorageClassTuple!s)
               {
                  static if (p == ParameterStorageClass.ref_)
                  {
                     static assert(0, fullyQualifiedName!s ~ " is not a valid endpoint. Wrong storage class for params. Try to change its signature to `" ~ __traits(identifier,s) ~ "(Request request, Output output)`.");
                  }
               }

               FunctionPriority fp;

               fp.name = __traits(identifier,s);
               fp.mod = fullyQualifiedName!m;

               static if (getUDAs!(s, priority).length > 0 && !is(getUDAs!(s, priority)[0]))
                  fp.priority = getUDAs!(s, priority)[0].priority;


               fps ~= fp;
            }
         }}

         return fps.sort!((a,b) => a.priority > b.priority).array;

      }

      enum taggedHandlers = getTaggedHandlers();
      enum untaggedHandlers = getUntaggedHandlers();


      static if (taggedHandlers !is null && taggedHandlers.length>0)
      {
         bool callUntilIsDirty(FunctionPriority[] taggedHandlers)()
         {
            static foreach(ff; taggedHandlers)
            {
               {
                  mixin(`import ` ~ ff.mod ~ ";");
                  alias currentMod = mixin(ff.mod);
                  alias f = __traits(getMember,currentMod, ff.name);

                  import std.traits : hasUDA, TemplateOf, getUDAs;

                  bool willLaunch = true;
                  static if (hasUDA!(f, route))
                  {
                     willLaunch = false;
                     static foreach(attr;  getUDAs!(f, route))
                     {
                        {
                           if(attr.apply(request)) willLaunch = true;
                        }
                     }
                  }

                  if (willLaunch)
                  {
                     static if (__traits(compiles, f(request, output))) f(request, output);
                     else static if (__traits(compiles, f(request))) f(request);
                     else f(output);
                  }

                  request._internal._route ~= ff.mod ~ "." ~ ff.name;
               }

               if (output._internal._dirty) return true;
            }

            return false;
         }

        callUntilIsDirty!taggedHandlers;
      }
      else static if (untaggedHandlers !is null)
      {

         static if (untaggedHandlers.length != 1)
         {
            static assert(0, "Please tag each valid endpoint with @endpoint UDA.");
         }
         else
         {
            {
               mixin(`import ` ~ untaggedHandlers[0].mod ~ ";");
               alias currentMod = mixin(untaggedHandlers[0].mod);
               alias f = __traits(getMember,currentMod, untaggedHandlers[0].name);

               if (!output._internal._dirty)
               {
                  static if (__traits(compiles, f(request, output))) f(request, output);
                  else static if (__traits(compiles, f(request))) f(request);
                  else f(output);

                  request._internal._route ~= untaggedHandlers[0].mod ~ "." ~ untaggedHandlers[0].name;
               }
            }
         }
      }
      else static assert(0, "Please add at least one endpoint. Try this: `void hello(Request req, Output output) { output ~= req.dump(); }`");
   }

   ProcessInfo    daemonProcess;

   Request        request;
   Output         output;

   CoarseTime     startedAt;
   CoarseTime     idlingAt;

   Socket         channel;

   static size_t        requestId = 0;
   shared CoarseTime    processedStartedAt = CoarseTime.zero;
   __gshared bool       isDynamic = false;

}


void tryInit(Modules...)()
{
   import std.traits : getSymbolsByUDA, isFunction;

   static foreach(m; Modules)
   {
      static foreach(f;  getSymbolsByUDA!(m, onWorkerStart))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStart but it is not a function");

         static if (__traits(compiles, f())) f();
         else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStart but it is not callable");

      }}
   }
}

void tryUninit(Modules...)()
{
   import std.traits : getSymbolsByUDA, isFunction;

   static foreach(m; Modules)
   {
      static foreach(f;  getSymbolsByUDA!(m, onWorkerStop))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStop but it is not a function");

         static if (__traits(compiles, f())) f();
         else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStop but it is not callable");

      }}
   }
}

