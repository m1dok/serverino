serverino
<img align="left" alt="Logo" width="100" src="https://github.com/trikko/serverino/assets/647157/a6f462fa-8b76-43c3-9855-0671e704aa6c" height="96">
=======
[![BUILD & TEST](https://github.com/trikko/serverino/actions/workflows/d.yml/badge.svg)](https://github.com/trikko/serverino/actions/workflows/d.yml) [![Donate](https://img.shields.io/badge/paypal-buy_me_a_beer-FFEF00?logo=paypal&logoColor=white)](https://paypal.me/andreafontana/5)
###### [quickstart](#quickstart) – [minimal example](#a-simple-webserver-in-just-three-lines) – [wiki](https://github.com/trikko/serverino/wiki/) - [more examples](https://github.com/trikko/serverino/tree/master/examples/) - [docs]( #documentation-you-need) – [shielding serverino using proxy](#shielding-the-whole-thing)
---
* 🚀 **Quick build & start**: *build & run your server in seconds.*
* 🙌 **Zero dependencies**: *serverino doesn’t rely on any external library.*
* 💪 **High performance**: *capable of managing tens of thousands of connections per second.*
* 🌐 **Cross-platform**: *every release is tested on Linux, Windows, and MacOS.*

## Quickstart
```
dub init your_fabulous_project -t serverino
cd your_fabulous_project
dub run
```

## A simple webserver in just three lines
```d
import serverino;
mixin ServerinoMain;
void simple(Request request, Output output) { output ~= request.dump(); }
```

## Documentation you need
* [Serverino docs](https://trikko.github.io/serverino/) - Serverino reference, generated from code
* [Examples](https://github.com/trikko/serverino/tree/master/examples) - Some ready-to-try examples
* [Tips](https://github.com/trikko/serverino/wiki/) - Some snippets you want to read

## Defining more than one endpoint
**Every function marked with ```@endpoint``` is called until one writes something to output**

The calling order is defined by ```@priority```

```d
module app;

import std;
import serverino;

mixin ServerinoMain;

// This endpoint handles the root of the server. Try: http://localhost:8080/
@endpoint @route!"/"
void homepage(Request request, Output output)
{
	output ~= `<html><body>`;
	output ~= `<a href="/private/profile">Private page</a><br>`;
	output ~= `<a href="/private/asdasd">Private (404) page</a>`;
	output ~= `</body></html>`;
}

// This endpoint shows a private page: it's protected by the auth endpoint below.
@endpoint @route!"/private/profile"
void user(Request request, Output output) 
{ 
	output ~= "Hello user!"; 
}

// This endpoint shows a private page: it's protected by the auth endpoint below.
@endpoint 
void blah(Request request, Output output)
{
	// Same as marking this endpoint with @route!"/private/dump" 
	if (request.uri != "/private/dump") 
		return;

	output ~= request.dump();
}

// This endpoint simply checks if the user and password are correct for all the private pages.
// Since it has a higher priority than the previous endpoints, it will be called first.
@priority(10)
@endpoint @route!(r => r.uri.startsWith("/private/"))
void auth(Request request, Output output)
{
	if (request.user != "user" || request.password != "password")
	{
		// If the user and password are not correct, we return a 401 status code and a www-authenticate header.
		output.status = 401;
		output.addHeader("www-authenticate",`Basic realm="my serverino"`);
	}

	// If the user and password are correct, we call the next matching endpoint.
	// (the next matching endpoint will be called only if the current endpoint doesn't write anything)
}

// This endpoint has the highest priority between the endpoints and it logs all the requests.
@priority(12) @endpoint
void requestLog(Request request)
{
	// There's no http output, so the next endpoint will be called.
	info("Request: ", request.uri);
}
```

## Shielding the whole thing
I would not put serverino into the wild. For using in production I suggest shielding serverino under a full webserver.

### Using nginx
It's pretty easy. Just add these lines inside your nginx configuration:

```
server {
   listen 80 default_server;
   listen [::]:80 default_server;
   
   location /your_path/ {
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      
      proxy_pass http://localhost:8080;
   }
   ...
   ...
}
```

If you want to enable keepalive (between nginx and serverino) you must use an upstream:

```
upstream your_upstream_name {
  server localhost:8080;
  keepalive 64;
}


server {
   listen 80 default_server;
   listen [::]:80 default_server;

   location /your_path/ {
      proxy_set_header Connection "";
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      
      proxy_pass http://your_upstream_name;
    }
    
    ...
    ...
 }
```
### Using apache2
Enable proxy module for apache2:
```
sudo a2enmod proxy
sudo a2enmod proxy_http
```

Add a proxy in your virtualhost configuration:
```
<VirtualHost *:80>
   ProxyPass "/"  "http://localhost:8080/"
   ...
</VirtualHost>
```
