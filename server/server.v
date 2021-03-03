// from: https://github.com/vlang/v/pull/1142
// See also: https://www.w3.org/Protocols/rfc2616/rfc2616-sec4.html
module server

import net
import io
import strings
import utils
import time

const (
	sep = '\r\n'
)

// Router interface for a generic Router
pub interface Router {
	respond_error(code int) []byte
	receive(method string, path string, raw_headers []string, body []byte) (int, []byte, []byte)
	add_plugin(plugin &Plugin) int
}

// Plugin interface of a generic Plugin
pub interface Plugin {
	name         string
	version      string // semver string
	init()
	info()       map[string]string
	close()
	// dependencies() []string // dependency on other plugins (by name)
	// status() PluginStatus
mut:
	app          voidptr // reference to the app
}

// TODO: remove when related PR will be merged ... wip
// str return a string representation (as summary) of the plugin
pub fn (p &Plugin) str() string {
	return 'Plugin{ name:$p.name, version:$p.version }'
	// return 'server.Plugin{ ... }'
}

// register add a plugin and initializes it
pub fn register(mut router Router, mut plugin Plugin) {
	num := router.add_plugin(plugin)
	if num >= 0 {
		// TODO: with this enabled, I get: RUNTIME ERROR: invalid memory access, fix ... in the meantime, keep it enabled in server ... wip
		// plugin.app = router // set a reference to the app, useful in some cases // later check if enable here instead of the Router
		plugin.init() // initializes the plugin
		println(utils.green_log('Plugin registered and initialized: "$plugin.info()"'))
	}
}

// serve starts the server at the give port
pub fn serve(router Router, port int) {
	// Listen To Port
	mut listener := net.listen_tcp(port) or {
		panic(utils.red_log('Failed to listen to port $port'))
	}
	println(utils.green_log('HTTP Server has started.'))
	println(utils.green_log('Running On http://localhost:$port'))
	for {
		mut conn := listener.accept() or {
			listener.close() or { }
			panic(utils.red_log('Failed to accept connection.'))
		}
		handle_http_connection(router, mut conn)
	}
}

// write_body Writes The Response Body into the TCP server
fn write_body(code int, headers []byte, body []byte, mut conn net.TcpConn) {
	mut response := strings.new_builder(body.len)
	response.write_string('HTTP/1.1 $code ' + utils.status_code_msg(code))
	unsafe { response.write_bytes(headers.data, headers.len) }
	response.write_string('${server.sep}Content-Length: $body.len')
	response.write_string('${server.sep}Connection: close')
	response.write_string(server.sep.repeat(2))
	unsafe { response.write_bytes(body.data, body.len) }
	conn.write(response.buf) or { }
	unsafe { response.free() }
}

// Handle All HTTP Connections
fn handle_http_connection(router Router, mut conn net.TcpConn) {
	conn.set_read_timeout(1 * time.second)
	defer {
		conn.close() or { }
	}
	mut reader := io.new_buffered_reader(reader: io.make_reader(conn))
	first_line := reader.read_line() or {
		$if debug {
			eprintln('Failed To Read First Line') // show this only in debug mode, because it always would be shown after a chromium user visits the site
		}
		return
	}
	data := first_line.split(' ')
	if data.len < 2 {
		bad_req_body := router.respond_error(400)
		write_body(400, []byte{}, bad_req_body, mut conn)
		return
	}
	mut raw_headers := []string{}
	mut conlen := 0
	mut rbody := []byte{}
	// encode headers
	for {
		header_line := reader.read_line() or {
			internal_err_body := router.respond_error(500)
			write_body(500, []byte{}, internal_err_body, mut conn)
			return
		}
		if header_line.starts_with('Content-Length: ') {
			conlen = header_line.all_after('Content-Length: ').int()
		}
		if header_line.len == 0 {
			break
		}
		raw_headers << header_line
	}
	if conlen > 0 {
		rbody = io.read_all(reader: reader) or { []byte{} }
	}
	status_code, enc_header, body := router.receive(data[0], data[1], raw_headers, rbody)
	write_body(status_code, enc_header, body, mut conn)
	unsafe { raw_headers.free() }
}
