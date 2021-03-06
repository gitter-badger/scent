'use strict'

log = (require 'debug') 'scent:entity'
_ = require 'lodash'
NoMe = require 'nome'
fast = require 'fast.js'

{Symbol, Map} = require 'es6'
Component = require './component'

symbols = require './symbols'
bEntity = Symbol 'represent entity reference on the component'
bComponents = Symbol 'map of components in the entity'
bSetup = Symbol 'private setup method for entity'
bComponentChanged = Symbol 'timestamp of change of component list'
bDisposedComponents = Symbol 'list of disposed components'

# Entity constructor function. Accepts optional array of component
# instances that are about to be added to entity right away.
Entity = (components) ->
	entity = this
	unless entity instanceof Entity
		entity = new Entity

	entity[ bComponents ] = new Map
	entity[ bSetup ] components
	return entity

# Adds component instance to entity. Only single instance of one
# component type can be added. Trying to add component of same type
# preserves the previous one while issuing log message to be notified
# about possible logic error.
Entity::add = (component) ->
	validateComponent component

	return this if componentIsShared(component, this)

	if @has componentType = component[ symbols.bType ]
		log 'entity already contains component `%s`, consider using replace method if this is intended', componentType.typeName
		log (new Error).stack
		return this

	Entity.componentAdded.call this, component
	return this

# Remove component type from the entity and removed component
# is marked for disposal.
Entity::remove = (componentType) ->
	validateComponentType componentType
	Entity.componentRemoved.call this, componentType

# Similar to add method, but disposes component of the same type
# before adding new one.
Entity::replace = (component) ->
	validateComponent component

	return this if componentIsShared(component, this)

	# remove component of same type if present
	this.remove component[ symbols.bType ]

	Entity.componentAdded.call this, component
	return this

# Check the existence of component type within entity.
# Always returns boolean value.
# Passing true in second argument will consider currently disposed
# components.
Entity::has = (componentType, allowDisposed) ->
	validateComponentType componentType

	unless this[ bComponents ].has componentType
		return false
	return this.get(componentType, allowDisposed) isnt null

# Retrieve component instance by specified type.
# Returns NULL if no component of such type is present.
# Passing true in second argument will consider currently disposed
# components.
Entity::get = (componentType, allowDisposed) ->
	validateComponentType componentType

	unless component = this[ bComponents ].get(componentType)
		return null

	if component[ symbols.bDisposing ]
		return if allowDisposed is yes then component else null

	return component

# Read-only property returning number of components in entity.
Object.defineProperty Entity.prototype, 'size',
	enumerable: yes
	get: -> this[ bComponents ].size

# Read-only property returning timestamp of the latest change to entity
Object.defineProperty Entity.prototype, 'changed',
	enumerable: yes
	get: ->
		return 0 unless changed = this[ bComponentChanged ]
		components = this[ bComponents ].values()
		entry = components.next()
		while not entry.done
			changed = Math.max changed, entry.value[ symbols.bChanged ]
			entry = components.next()
		return changed

# Method called when new component is added to entity.
# It is wrapped by NoMe so other parts can be notified.
# Expected to be called in context of entity instance.
Entity.componentAdded = NoMe (component) ->
	if this[ symbols.bDisposing ]
		log 'component cannot be added when entity is being disposed (since %d)', this[ symbols.bDisposing ]
		log (new Error).stack
		return

	component[ bEntity ] = this
	this[ bComponents ].set component[ symbols.bType ], component
	# update timestamp of entity change
	this[ bComponentChanged ] = Date.now()
	return this

# Method called when a component is removed from entity.
# It is wrapped by NoMe so other parts can be notified.
# Expected to be called in context of entity instance.
Entity.componentRemoved = NoMe (componentType) ->
	if this[ symbols.bDisposing ]
		log 'component cannot be removed when entity is being disposed (since %d)', this[ symbols.bDisposing ]
		log (new Error).stack
		return

	if component = this[ bComponents ].get componentType
		do component[ symbols.bDispose ]
		# update timestamp of entity change
		this[ bComponentChanged ] = Date.now()
	return this

## POOLING

entityPool = []

# Returns entity from pool of disposed ones or created entity instance.
# Accepts array of components same as Entity constructor.
Entity.pooled = (components) ->
	return new Entity components unless entityPool.length
	entity = entityPool.pop()
	entity[ bSetup ] components
	return entity

## DISPOSING

# Method to dispose entity instance and contained components.
# It is wrapped by NoMe so other parts can be notified.
# Expected to be called in context of entity instance.
Entity.disposed = NoMe ->
	this[ symbols.bDisposing ] = Date.now()
	components = this[ bComponents ].values()
	componentEntry = components.next()
	while not componentEntry.done
		do componentEntry.value[ symbols.bDispose ]
		componentEntry = components.next()

# Shortcut method to dispose entity instance.
Entity::dispose = Entity.disposed

# Watch for globally disposed components and those that
# are attached to some entity should be removed from entity.
Component.disposed.notify ->
	return unless entity = this[ bEntity ]

	# entity is being disposed, no point in handling
	# component disposal one by one
	return if entity[ symbols.bDisposing ]

	# disposed components are stored in list so these can be
	# removed in release() method
	unless list = entity[ bDisposedComponents ]
		list = entity[ bDisposedComponents ] = poolArray()
	list.push this

## RELEASING

Entity::release = ->
	cList = this[ bComponents ]

	if dList = this[ bDisposedComponents ]
		# loop through disposed components and release them
		for component in dList
			continue unless releaseComponent component
			componentType = component[ symbols.bType ]
			continue unless component is cList.get(componentType)
			cList.delete componentType
		dList.length = 0
		poolArray dList
		this[ bDisposedComponents ] = null

	if this[ symbols.bDisposing ]
		this[ bComponents ].forEach releaseComponent
		this[ bComponents ].clear()
		delete this[ bComponentChanged ]
		delete this[ symbols.bDisposing ]
		entityPool.push this
		return true

	return false

# Method to retrieve list of components within entity.
# Optionally array can be supplied to store results in
#   otherwise new array is created
# Expected to be called in context of entity instance.
Entity.getAll = (result = []) ->
	unless this instanceof Entity
		throw new TypeError 'expected entity instance for the context'
	components = this[ bComponents ].values()
	entry = components.next()
	while not entry.done
		result.push entry.value
		entry = components.next()
	return result

# Check if component is already used by other entity
componentIsShared = (component, entity) ->
	if result = inEntity = component[ bEntity ] and inEntity isnt entity
		log 'component %s cannot be shared with multiple entities', component
		log (new Error).stack
	return result

# Release resources for the component regarding the entity
releaseComponent = (component) ->
	released = do component[ symbols.bRelease ]
	delete component[ bEntity ] if released
	return released

validateComponent = (component) ->
	unless component
		throw new TypeError 'missing component for entity'
	validateComponentType component[ symbols.bType ]

validateComponentType = (componentType) ->
	unless componentType instanceof Component
		throw new TypeError 'invalid component type for entity'

# Internal method to setup entity instance.
Entity::[ bSetup ] = (components) ->
	if components and not (components instanceof Array)
		throw new TypeError 'expected array of components for entity'

	# Add components passed in constructor
	fast.forEach components, this.add, this if components
	return

Entity::inspect = ->
	result = {
		"--changed": this.changed
	}

	if this[ symbols.bDisposing ]
		result['--disposing'] = this[ symbols.bDisposing ]

	if dList = this[ bDisposedComponents ]
		result['--disposedComponents'] = resultList = []
		resultList.push component.inspect() for component in dList

	components = this[ bComponents ].values()
	entry = components.next()
	while not entry.done
		component = entry.value
		result[component[ symbols.bName ]] = component.inspect()
		entry = components.next()
	return result

# Simple pool of array objects to be used internally.
arrayPool = []
poolArray = (add) ->
	return arrayPool.push add if add
	return [] unless arrayPool.length
	return arrayPool.pop()

# DEPRECATED
Entity::[ symbols.bDispose ] = ->
	log 'using symbol bDispose is deprecated, use direct `dispose` method instead'
	log (new Error).stack
	this.dispose()

# DEPRECATED
Object.defineProperty Entity.prototype, symbols.bChanged,
	get: ->
		log 'using bChanged symbol for entity is DEPRECATED, use direct changed property'
		log (new Error).stack
		return this.changed

module.exports = Object.freeze Entity
