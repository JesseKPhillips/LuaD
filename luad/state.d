module luad.state;

import std.string;

import luad.c.all;
import luad.stack;

import luad.base, luad.table, luad.lfunction, luad.error;

/**
 * Represents a Lua state instance.
 */
class LuaState
{
private:
	lua_State* L;
	LuaTable _G, _R;
	bool owner = false;
	
public:
	/**
	 * Create a new, empty Lua state. The standard library is not loaded.
	 *
	 * If an uncaught error for any operation on this state
	 * causes a Lua panic for the underlying state, 
	 * an exception of type LuaError is thrown.
	 *
	 * See_Also: openLibs
	 */
	this()
	{
		lua_State* L = luaL_newstate();
		owner = true;
		
		extern(C) static int panic(lua_State* L)
		{
			size_t len;
			const(char)* cMessage = lua_tolstring(L, -1, &len);
			string message = cMessage[0 .. len].idup;
			
			lua_pop(L, 1);
			
			throw new LuaErrorException(message);
		}
		
		lua_atpanic(L, &panic);
		
		this(L);
	}
	
	/**
	 * Create a D wrapper for an existing Lua state.
	 *
	 * The new LuaState does not assume ownership of the state.
	 *
	 * Note: 
	 *	 The panic function is not changed - a Lua panic will not throw a D exception!
	 * Params:
	 *	 L = state to wrap.
	 */
	this(lua_State* L)
	{
		this.L = L;
		_G = LuaTable(L, LUA_GLOBALSINDEX);
		_R = LuaTable(L, LUA_REGISTRYINDEX);
		
		lua_pushlightuserdata(L, cast(void*)this);
		lua_setfield(L, LUA_REGISTRYINDEX, "__dstate");
	}
	
	~this()
	{
		if(owner)
			lua_close(L);
	}
	
	/**
	 * Get the LuaState instance for a Lua state.
	 * Params:
	 *	 L = Lua state
	 * Returns:
	 *	 LuaState for the given lua_State*.
	 */
	static LuaState fromPointer(lua_State* L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__dstate");
		scope(exit) lua_pop(L, 1);
		return cast(LuaState)lua_touserdata(L, -1);
	}
	
	/// Open the standard library.
	void openLibs()
	{
		luaL_openlibs(L);
	}
	
	/// The global table for this instance.
	@property LuaTable globals()
	{
		return _G;
	}
	
	/// The _registry table for this instance.
	@property LuaTable registry()
	{
		return _R;
	}
	
	/**
	 * Set a new panic handler.
	 * Params:
	 *	 onPanic = new panic handler
	 * Examples:
	 * ----------------------
	auto L = luaL_newstate(); // found in luad.c.all
	auto lua = new LuaState(L);
	
	static void panic(LuaState lua, string error)
	{
		throw new LuaErrorException(error);
	}
	
	lua.setPanicHandler(&panic);
	 * ----------------------
	 */
	void setPanicHandler(void function(LuaState, string) onPanic)
	{
		extern(C) static int panic(lua_State* L)
		{
			size_t len;
			const(char)* message = lua_tolstring(L, -1, &len);
			auto error = message[0 .. len].idup;
			
			lua_getfield(L, LUA_REGISTRYINDEX, "__dpanic");
			auto callback = cast(void function(LuaState, string))lua_touserdata(L, -1);
			assert(callback);
			
			lua_pop(L, 2);
			
			callback(LuaState.fromPointer(L), error);
			return 0;
		}
		
		lua_pushlightuserdata(L, onPanic);
		lua_setfield(L, LUA_REGISTRYINDEX, "__dpanic");
		
		lua_atpanic(L, &panic);
	}

	/*
	 * push debug.traceback error handler to the stack
	 */
	private void pushErrorHandler()
	{
		lua_getfield(L, LUA_GLOBALSINDEX, "debug");
		lua_getfield(L, -1, "traceback");
		lua_remove(L, -2); // remove debug table from stack
	}

	/*
	 * a variant of luaL_do(string|file) with advanced error handling
	 */
	private void doChunk(alias loader)(in char[] s)
	{
	    pushErrorHandler();

	    if(loader(L, toStringz(s)) || lua_pcall(L, 0, LUA_MULTRET, -2))
            lua_error(L);

        lua_remove(L, 1);
	}

	/**
	 * Compile a string of Lua _code.
	 * Params:
	 *	 code = _code to compile
	 * Returns:
	 *   Loaded _code as a function.
	 */
	LuaFunction loadString(in char[] code)
	{
		if(luaL_loadstring(L, toStringz(code)) != 0)
			lua_error(L);

		return popValue!LuaFunction(L);
	}

	/**
	 * Compile a file of Lua code.
	 * Params:
	 *	 path = _path to file
	 * Returns:
	 *   Loaded code as a function.
	 */
	LuaFunction loadFile(in char[] path)
	{
		if(luaL_loadfile(L, toStringz(path)) != 1)
			lua_error(L);

		return popValue!LuaFunction(L);
	}

	/**
	 * Execute a string of Lua _code.
	 * Params:
	 *	 code = _code to run
	 * Returns:
	 *	 Any _code return values
	 */
	LuaObject[] doString(in char[] code)
	{
		doChunk!(luaL_loadstring)(code);
		return getStack(L);
	}
	

	/**
	 * Execute a file of Lua code.
	 * Params:
	 *	 path = _path to file
	 * Returns:
	 *	 Any script return values
	 */
	LuaObject[] doFile(in char[] path)
	{
		doChunk!(luaL_loadfile)(path);
		return getStack(L);
	}
	
	/**
	 * Create a new, empty table.
	 * Returns:
	 *	 The new table
	 */
	LuaTable newTable()
	{
		return newTable(0, 0);
	}
	
	/**
	 * Create a new, empty table with pre-allocated space for members.
	 * Params:
	 *	 narr = number of pre-allocated array slots
	 *	 nrec = number of pre-allocated non-array slots
	 * Returns:
	 *	 The new table
	 */
	LuaTable newTable(uint narr, uint nrec)
	{
		lua_createtable(L, narr, nrec);
		return popValue!LuaTable(L);
	}
	
	/**
	 * Wrap a D value in a LuaObject.
	 * Params:
	 *	 value = D value to _wrap
	 * Returns:
	 *	 A reference to value as a LuaObject
	 */
	LuaObject wrap(T)(T value)
	{
		pushValue(L, value);
		return popValue!LuaObject(L);
	}
	
	/**
	 * Same as calling globals._get with the same arguments.
	 * See Also:
	 *	 LuaTable._get
	 */
	T get(T, U...)(U args)
	{
		return globals.get!T(args);
	}
	
	/**
	 * Same as calling globals.get!LuaObject with the same arguments.
	 * See Also:
	 *	 LuaTable._opIndex
	 */
	LuaObject opIndex(T...)(T args)
	{
		return globals.get!LuaObject(args);
	}
	
	/**
	 * Same as calling globals._set with the same arguments.
	 * See Also:
	 *	 LuaTable._set
	 */
	void set(T, U)(T key, U value)
	{
		globals.set(key, value);
	}
	
	/**
	 * Same as calling globals._opIndexAssign with the same arguments.
	 * See Also:
	 *	 LuaTable._opIndexAssign
	 */
	void opIndexAssign(T, U...)(T value, U args)
	{
		globals()[args] = value;
	}
}

version(unittest) import std.string : splitLines;

unittest
{
	auto lua = new LuaState;
	assert(LuaState.fromPointer(lua.L) == lua);
	
	lua.openLibs();
	
	//default panic handler
	string msg;
	try
	{
		lua.doString(`error("Hello, D!")`);
	}
	catch(LuaErrorException e)
	{
		auto lines = splitLines(e.msg);
		assert(lines[0] == `[string "error("Hello, D!")"]:1: Hello, D!`);
	}
	
	lua.set("success", false);
	assert(!lua.get!bool("success"));
	
	lua.doString(`success = true`);
	assert(lua.get!bool("success"));
	
	// setPanicHandler
	static void panic(LuaState lua, string error)
	{
		throw new Exception("hijacked error!");
	}
	
	lua.setPanicHandler(&panic);
	
	try
	{
		lua.doString(`error("test")`);
	}
	catch(Exception e)
	{
		assert(e.msg == "hijacked error!");
	}
	
	lua["foo"] = lua.wrap("bar");
	lua.doString(`assert(foo == "bar")`);
	
	lua["foo"] = lua.wrap(12.34);
	lua.doString(`assert(foo == 12.34)`);

	LuaFunction multipleReturns = lua.loadString(`return 1, "two", 3`);
	LuaObject[] results = multipleReturns();
	
	assert(results.length == 3);
	assert(results[0].type == LuaType.Number);
	assert(results[1].type == LuaType.String);
	assert(results[2].type == LuaType.Number);
}
