###
Backbone dualStorage Adapter v1.1.0

A simple module to replace `Backbone.sync` with *localStorage*-based
persistence. Models are given GUIDS, and saved into a JSON object. Simple
as that.
###

# Make it easy for collections to sync dirty and destroyed records
# Simply call collection.syncDirtyAndDestroyed()
Backbone.Collection.prototype.syncDirty = ->
  url = result(@, 'url')
  storeName = result(@, 'storeName')
  store = localStorage.getItem "#{url}_dirty" || localStorage.getItem "#{storeName}_dirty"
  ids = (store and store.split(',')) or []

  for id in ids
    model = if id.length == 36 then @findWhere(id: id) else @get(id)
    model?.save()

Backbone.Collection.prototype.syncDestroyed = ->
  url = result(@, 'url')
  storeName = result(@, 'storeName')
  store = localStorage.getItem "#{url}_destroyed" || store = localStorage.getItem "#{storeName}_destroyed"
  ids = (store and store.split(',')) or []

  for id in ids
    model = new @model(id: id)
    model.collection = @
    model.destroy()

Backbone.Collection.prototype.syncDirtyAndDestroyed = ->
  @syncDirty()
  @syncDestroyed()

# Generate four random hex digits.
S4 = ->
  (((1 + Math.random()) * 0x10000) | 0).toString(16).substring 1

# Our Store is represented by a single JS object in *localStorage*. Create it
# with a meaningful name, like the name you'd give a table.
class window.Store
  sep: '' # previously '-'

  constructor: (name) ->
    @name = name
    @records = @recordsOn @name

  # Generates an unique id to use when saving new instances into localstorage
  # by default generates a pseudo-GUID by concatenating random hexadecimal.
  # you can overwrite this function to use another strategy
  generateId: ->
    S4() + S4() + '-' + S4() + '-' + S4() + '-' + S4() + '-' + S4() + S4() + S4()

  # Save the current state of the **Store** to *localStorage*.
  save: ->
    localStorage.setItem @name, @records.join(',')

  recordsOn: (key) ->
    store = localStorage.getItem(key)
    (store and store.split(',')) or []

  dirty: (model) ->
    dirtyRecords = @recordsOn @name + '_dirty'
    if not _.include(dirtyRecords, model.id.toString())
      dirtyRecords.push model.id
      localStorage.setItem @name + '_dirty', dirtyRecords.join(',')
    model

  clean: (model, from) ->
    store = "#{@name}_#{from}"
    dirtyRecords = @recordsOn store
    if _.include dirtyRecords, model.id.toString()
      localStorage.setItem store, _.without(dirtyRecords, model.id.toString()).join(',')
    model

  destroyed: (model) ->
    destroyedRecords = @recordsOn @name + '_destroyed'
    if not _.include destroyedRecords, model.id.toString()
      destroyedRecords.push model.id
      localStorage.setItem @name + '_destroyed', destroyedRecords.join(',')
    model

  # Add a model, giving it a unique GUID, if it doesn't already
  # have an id of it's own.
  create: (model) ->
    if not _.isObject(model) then return model
    if not model.id
      model.id = @generateId()
      model.set model.idAttribute, model.id
    localStorage.setItem @name + @sep + model.id, JSON.stringify(model)
    @records.push model.id.toString()
    @save()
    model

  # Update a model by replacing its copy in `this.data`.
  update: (model) ->
    localStorage.setItem @name + @sep + model.id, JSON.stringify(model)
    if not _.include(@records, model.id.toString())
      @records.push model.id.toString()
    @save()
    model

  clear: ->
    for id in @records
      localStorage.removeItem @name + @sep + id
    @records = []
    @save()

  hasDirtyOrDestroyed: ->
    not _.isEmpty(localStorage.getItem(@name + '_dirty')) or not _.isEmpty(localStorage.getItem(@name + '_destroyed'))

  # Retrieve a model from `this.data` by id.
  find: (model) ->
    modelAsJson = localStorage.getItem(@name + @sep + model.id)
    return null if modelAsJson == null
    JSON.parse modelAsJson

  # Return the array of all models currently in storage.
  findAll: ->
    for id in @records
      JSON.parse localStorage.getItem(@name + @sep + id)

  # Delete a model from `this.data`, returning it.
  destroy: (model) ->
    localStorage.removeItem @name + @sep + model.id
    @records = _.reject(@records, (record_id) ->
      record_id is model.id.toString()
    )
    @save()
    model

callbackTranslator =
  needsTranslation: Backbone.VERSION == '0.9.10'

  forBackboneCaller: (callback) ->
    if @needsTranslation
      (model, resp, options) -> callback.call null, resp
    else
      callback

  forDualstorageCaller: (callback, model, options) ->
    if @needsTranslation
      (resp) -> callback.call null, model, resp, options
    else
      callback

# Override `Backbone.sync` to use delegate to the model or collection's
# *localStorage* property, which should be an instance of `Store`.
localsync = (method, model, options) ->
  isValidModel = (method is 'clear') or (method is 'hasDirtyOrDestroyed')
  isValidModel ||= model instanceof Backbone.Model
  isValidModel ||= model instanceof Backbone.Collection

  if not isValidModel
    throw new Error 'model parameter is required to be a backbone model or collection.'

  store = new Store options.storeName

  response = switch method
    when 'read'
      if model.id
        store.find(model)
      else
        store.findAll()
    when 'hasDirtyOrDestroyed'
      store.hasDirtyOrDestroyed()
    when 'clear'
      store.clear()
    when 'create'
      unless options.add and not options.merge and (preExisting = store.find(model))
        model = store.create(model)
        store.dirty(model) if options.dirty
        model
      else
        preExisting
    when 'update'
      store.update(model)
      if options.dirty
        store.dirty(model)
      else
        store.clean(model, 'dirty')
    when 'delete'
      store.destroy(model)
      if options.dirty
        store.destroyed(model)
      else
        if model.id.toString().length == 36
          store.clean(model, 'dirty')
        else
          store.clean(model, 'destroyed')
  response = response.attributes if response?.attributes

  unless options.ignoreCallbacks
    if response
      options.success response
    else
      options.error 'Record not found'

  response

# If the value of the named property is a function then invoke it;
# otherwise, return it.
# based on _.result from underscore github
result = (object, property) ->
  return null unless object
  value = object[property]
  if _.isFunction(value) then value.call(object) else value

# Helper function to run parseBeforeLocalSave() in order to
# parse a remote JSON response before caching locally
parseRemoteResponse = (object, response) ->
  if not (object and object.parseBeforeLocalSave) then return response
  if _.isFunction(object.parseBeforeLocalSave) then object.parseBeforeLocalSave(response)

modelUpdatedWithResponse = (model, response) ->
  modelClone = new Backbone.Model
  modelClone.idAttribute = model.idAttribute
  modelClone.set model.attributes
  modelClone.set modelClone.parse response
  modelClone

backboneSync = Backbone.sync
onlineSync = (method, model, options) ->
  options.success = callbackTranslator.forBackboneCaller(options.success)
  options.error   = callbackTranslator.forBackboneCaller(options.error)
  backboneSync(method, model, options)

dualsync = (method, model, options) ->
  options.storeName = result(model.collection, 'storeName') || result(model, 'storeName') ||
                      result(model.collection, 'url')       || result(model, 'urlRoot')   || result(model, 'url')
  options.success = callbackTranslator.forDualstorageCaller(options.success, model, options)
  options.error   = callbackTranslator.forDualstorageCaller(options.error, model, options)

  # execute only online sync
  return onlineSync(method, model, options) if result(model, 'remote') or result(model.collection, 'remote')

  # execute only local sync
  local = result(model, 'local') or result(model.collection, 'local')
  options.dirty = options.remote is false and not local
  return localsync(method, model, options) if options.remote is false or local

  # execute dual sync
  options.ignoreCallbacks = true

  success = options.success
  error = options.error

  switch method
    when 'read'
      if localsync('hasDirtyOrDestroyed', model, options)
        success localsync(method, model, options)
      else
        options.success = (resp, status, xhr) ->
          resp = parseRemoteResponse(model, resp)

          localsync('clear', model, options) unless options.add

          if _.isArray resp
            collection = model
            idAttribute = collection.model.prototype.idAttribute
            for modelAttributes in resp
              model = collection.get(modelAttributes[idAttribute])
              if model
                responseModel = modelUpdatedWithResponse(model, modelAttributes)
              else
                responseModel = new collection.model(modelAttributes)
              localsync('create', responseModel, options)
          else
            responseModel = modelUpdatedWithResponse(model, resp)
            localsync('create', responseModel, options)

          success(resp, status, xhr)

        options.error = (resp) ->
          success localsync(method, model, options)

        onlineSync(method, model, options)

    when 'create'
      options.success = (resp, status, xhr) ->
        updatedModel = modelUpdatedWithResponse model, resp
        localsync(method, updatedModel, options)
        success(resp, status, xhr)
      options.error = (resp) ->
        options.dirty = true
        success localsync(method, model, options)

      onlineSync(method, model, options)

    when 'update'
      if _.isString(model.id) and model.id.length == 36
        temporaryId = model.id

        options.success = (resp, status, xhr) ->
          updatedModel = modelUpdatedWithResponse model, resp
          model.set model.idAttribute, temporaryId, silent: true
          localsync('delete', model, options)
          localsync('create', updatedModel, options)
          success(resp, status, xhr)
        options.error = (resp) ->
          options.dirty = true
          model.set model.idAttribute, temporaryId, silent: true
          success localsync(method, model, options)

        model.set model.idAttribute, null, silent: true
        onlineSync('create', model, options)
      else
        options.success = (resp, status, xhr) ->
          updatedModel = modelUpdatedWithResponse model, resp
          localsync(method, updatedModel, options)
          success(resp, status, xhr)
        options.error = (resp) ->
          options.dirty = true
          success localsync(method, model, options)

        onlineSync(method, model, options)

    when 'delete'
      if _.isString(model.id) and model.id.length == 36
        localsync(method, model, options)
      else
        options.success = (resp, status, xhr) ->
          localsync(method, model, options)
          success(resp, status, xhr)
        options.error = (resp) ->
          options.dirty = true
          success localsync(method, model, options)

        onlineSync(method, model, options)

Backbone.sync = dualsync
