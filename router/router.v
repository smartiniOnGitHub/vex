module router

import ctx

pub type GroupCallbackFn =  fn (mut group map[string]&Route)

enum Kind {
	wildcard
	param
	regular
}

pub struct Router {
mut:
	routes map[string]&Route
	middlewares []ctx.MiddlewareFunc
}

// route is a shortcut method to `r.routes.route` method
pub fn (mut r Router) route(method Method, path string, handlers ...ctx.HandlerFunc) {
	r.routes.route(method, path, ...handlers)
}

// group is a shortcut method to `r.routes.group` method
pub fn (mut r Router) group(prefix string, callback GroupCallbackFn) {
	r.routes.group(prefix, callback)
}

// find is a shortcut method to `r.routes.find` method
pub fn (r Router) find(method string, path string) ?(map[string]string, []ctx.MiddlewareFunc, []ctx.HandlerFunc) {
	return r.routes.find(method, path)
}

// use registers handlers as app-wide middlewares
pub fn (mut r Router) use(handlers ...ctx.HandlerFunc) {
	r.middlewares << handlers
}

// List of supported HTTP methods.
pub enum Method {
	get
	post
	patch
	put
	delete
	options
}

[ref_only]
pub struct Route {
	name        string
	param_name  string
	method      Method
	kind        Kind
mut:
	children    map[string]&Route
	methods     map[string][]ctx.HandlerFunc
	middlewares []ctx.MiddlewareFunc
}

// empty str to avoid cgen error
pub fn (r &Route) str() string {
	return ''
}

fn identify_kind(route_name string) Kind {
	if route_name.len == 0 {
		return .regular
	}
	match route_name[0] {
		`:` { return .param }
		`*` { return .wildcard }
		else { return .regular }
	}
}

// extract_route_path returns the name, the parameter name (if present),
// and the remaining children route paths
pub fn extract_route_path(path string) ?(string, string, string) {
	if !path.starts_with('/') {
		return error('route path must start with a slash (/)')
	}
	mut paths := path[1..].split('/')
	mut param_name := ''
	mut children := ''
	mut name := paths[0]
	mut has_wildcard := false
	if name.len >= 1 && name[0] in [`:`, `*`] {
		has_wildcard = name[0] == `*`
		param_name = if has_wildcard && name.len == 1 { '*' } else { name[1..] }
		name = name[0].str()
	}
	if paths.len > 1 {
		if has_wildcard {
			return error('wildcard routes should not have children routes')
		}
		children = '/' + paths[1..].join('/')
	}
	$if debug {
		println('name: $name | param_name: $param_name | children: $children')
	}
	return name, param_name, children
}

// add creates a new route based on the given method, path, and the handlers.
// See `router.Method` for the list of available methods.
fn (mut routes map[string]&Route) add(method Method, path string, handlers ...ctx.HandlerFunc) ? {
	if '*' in routes || ':' in routes {
		return error('only one wildcard or param route in an endpoint group is allowed.')
	}
	name, param_name, children := extract_route_path(path) ?
	if name !in routes {
		routes[name] = &Route{
			method: method
			param_name: param_name
			name: name
			kind: identify_kind(name)
		}
	}
	if children.len > 0 {
		routes[name].children.add(method, children, ...handlers) ?
		return
	} else if handlers.len == 0 {
		return error('provided route handlers are empty')
	}
	method_str := method.str()
	routes[name].methods[method_str] = handlers
}

// find searches the matching route and returns the injected params data and the route handlers.
pub fn (routes map[string]&Route) find(method string, path string) ?(map[string]string, []ctx.MiddlewareFunc, []ctx.HandlerFunc) {
	mut r_name, mut param_name, children := extract_route_path(path) ?
	mut params := map[string]string{}
	param_value := r_name
	if r_name !in routes {
		if ':' in routes || '*' in routes {
			r_name = if '*' in routes { '*' } else { ':' }
			param_name = routes[r_name].param_name
		} else {
			return error('not found')
		}
	}
	match r_name {
		':' { params[param_name] = param_value }
		'*' { params[param_name] = param_value + children }
		else {}
	}
	route := routes[r_name]
	if r_name != '*' && children.len > 0 {
		child_params, child_route_middlewares, handlers := route.children.find(method, children) ?
		for name, value in child_params {
			params[name] = value
		}
		unsafe { child_params.free() }
		return params, child_route_middlewares, handlers
	} else if method !in route.methods {
		return error('method not found')
	}
	return params, route.middlewares, route.methods[method]
}

// route creates a new route based on the given method, path, and the handlers.
// See `router.Method` for the list of available methods.
pub fn (mut routes map[string]&Route) route(method Method, path string, handlers ...ctx.HandlerFunc) {
	routes.add(method, path, ...handlers) or { panic(err) }
}

// group adds a series of routes into the desired prefix
pub fn (mut routes map[string]&Route) group(path string, callback GroupCallbackFn, middlewares ...ctx.MiddlewareFunc) {
	mut new_routes := map[string]&Route{}
	mut route := &Route{}
	mut children := path
	callback(mut new_routes)

	mut name := ''
	mut cur_routes := routes
	for children.len > 0 {
		new_name, param_name, new_children := extract_route_path(children) or { panic(err) }
		children = new_children
		name = new_name

		if ('*' in cur_routes || ':' in cur_routes) && name !in ['*', ':'] {
			panic('only one wildcard or param route in an endpoint group is allowed.')
		} else if name !in cur_routes {
			cur_routes.add(.get, '/$name$param_name$children', ctx.send_404) or { panic(err) }
		}

		route = unsafe { cur_routes[name] }
		cur_routes = &route.children
	}
	
	for new_path, new_route in new_routes {
		if new_path.len == 0 {
			for method_name, new_handlers in new_route.methods {
				route.methods[method_name] = new_handlers
				route.middlewares << middlewares
			}
			continue
		}

		unsafe { 
			cur_routes[new_path] = new_route 
			cur_routes[new_path].middlewares << middlewares
		}
	}

	unsafe { new_routes.free() }
}