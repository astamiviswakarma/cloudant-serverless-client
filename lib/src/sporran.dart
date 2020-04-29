/*
 * Package : Sporran
 * Author : S. Hamblett <steve.hamblett@linux.com>
 * Date   : 05/02/2014
 * Copyright :  S.Hamblett@OSCF
 * 
 * Sporran is a pouchdb alike for Dart.
 *
 */

part of sporran;

// ignore_for_file: omit_local_variable_types
// ignore_for_file: unnecessary_final
// ignore_for_file: cascade_invocations
// ignore_for_file: avoid_print
// ignore_for_file: avoid_annotating_with_dynamic
// ignore_for_file: avoid_types_on_closure_parameters
// ignore_for_file: public_member_api_docs

///  This is the main Sporran API class.
///
///  Please read the usage and interface documentation supplied for
/// further details.
class Sporran {
  /// Construction.
  Sporran(SporranInitialiser initialiser) {
    if (initialiser == null) {
      throw SporranException(SporranException.noInitialiserEx);
    }

    _dbName = initialiser.dbName;

    // Construct our database.
    _database = _SporranDatabase(
        _dbName,
        initialiser.hostname,
        initialiser.manualNotificationControl,
        initialiser.port,
        initialiser.scheme,
        initialiser.username,
        initialiser.password,
        initialiser.accessToken,
        initialiser.preserveLocal);

    // Online/offline listeners
    window.onOnline.listen((_) => _transitionToOnline());
    window.onOffline.listen((_) => _online = false);
  }

  /// Method constants
  static const String putc = 'put';
  static const String getc = 'get';
  static const String deletec = 'delete';
  static const String putAttachmentc = 'put_attachment';
  static const String getAttachmentc = 'get_attachment';
  static const String deleteAttachmentc = 'delete_attachment';
  static const String bulkCreatec = 'bulk_create';
  static const String getAllDocsc = 'get_all_docs';
  static const String dbInfoc = 'db_info';

  /// Database
  _SporranDatabase _database;

  /// Database name
  String _dbName;

  String get dbName => _dbName;

  /// Lawndart database
  Store get lawndart => _database.lawndart;

  /// Lawndart databse is open
  bool get lawnIsOpen => _database.lawnIsOpen;

  /// Wilt database
  Wilt get wilt => _database.wilt;

  bool _online = true;

  /// On/Offline indicator
  bool get online {
    /* If we are not online or we are and the CouchDb database is not
     * available we are offline
     */
    if ((!_online) || (_database.noCouchDb)) {
      return false;
    }
    return true;
  }

  set online(bool state) {
    _online = state;
    if (state) {
      _transitionToOnline();
    }
  }

  dynamic _clientCompleter;

  /// Completion function
  // ignore: avoid_setters_without_getters
  set clientCompleter(JsonObjectLite<dynamic> completer) =>
      _clientCompleter = completer;

  /// Response getter for completion callbacks
  JsonObjectLite<dynamic> _completionResponse;

  JsonObjectLite<dynamic> get completionResponse => _completionResponse;

  /// Pending delete queue size
  int get pendingDeleteSize => _database.pendingLength();

  /// Ready event
  Stream<dynamic> get onReady => _database.onReady;

  /// Manual notification control
  bool get manualNotificationControl => _database.manualNotificationControl;

  /// Start change notification manually
  void startChangeNotifications() {
    if (manualNotificationControl) {
      if (_database.wilt.changeNotificationsPaused) {
        _database.wilt.restartChangeNotifications();
      } else {
        _database.startChangeNotifications();
      }
    }
  }

  /// Stop change notification manually
  void stopChangeNotifications() {
    if (manualNotificationControl) {
      _database.wilt.pauseChangeNotifications();
    }
  }

  /// Manual control of sync().
  ///
  /// Usually Sporran syncs when a transition to online is detected,
  /// however this can be disabled, use in conjunction with manual
  /// change notification control. If this is set to false you must
  /// call sync() explicitly.
  bool autoSync = true;

  /// Raise an exception from a future API call.
  /// If we are using completion throw an exception as normal.
  Future<SporranException> _raiseException(String name) {
    if (_clientCompleter == null) {
      return Future<SporranException>.error(SporranException(name));
    } else {
      throw SporranException(name);
    }
  }

  /// Online transition
  void _transitionToOnline() {
    _online = true;

    /**
     * If we have never connected to CouchDb try now,
     * otherwise we can sync straight away
     */
    if (_database.noCouchDb) {
      _database.connectToCouch(true);
    } else {
      if (autoSync) {
        sync();
      }
    }
  }

  /// Common completion response creator for all databases
  dynamic _createCompletionResponse(dynamic result) {
    final dynamic completion = JsonObjectLite<dynamic>();

    completion.operation = result.operation;
    completion.payload = result.payload;
    completion.localResponse = result.localResponse;
    completion.id = result.id;
    completion.rev = result.rev;

    /**
     * Check for a local or Wilt response
     */
    if (result.localResponse) {
      completion.ok = result.ok;
    } else {
      if (result.error) {
        completion.ok = false;
        completion.errorCode = result.errorCode;
        completion.errorText = result.jsonCouchResponse.error;
        completion.errorReason = result.jsonCouchResponse.reason;
      } else {
        completion.ok = true;
      }
    }

    return completion;
  }

  /// Update document.
  ///
  /// If the document does not exist a create is performed.
  ///
  /// For an update operation a specific revision must be specified.
  Future<dynamic> put(String id, JsonObjectLite<dynamic> document,
      [String rev]) {
    final Completer<dynamic> opCompleter = Completer<dynamic>();

    if (id == null) {
      return _raiseException(SporranException.putNoDocIdEx);
    }

    /* Update LawnDart */
    _database
        .updateLocalStorageObject(
            id, document, rev, _SporranDatabase.notUpdatedc)
        // ignore: missing_return
        .then((_) {
      /* If we are offline just return */
      if (!online) {
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.operation = putc;
        res.ok = true;
        res.payload = document;
        res.id = id;
        res.rev = rev;

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
        return opCompleter.future;
      }

      /* Complete locally, then boomerang to the client */
      void completer(dynamic res) {
        /* If success, mark the update as UPDATED in local storage */
        res.ok = false;
        res.localResponse = false;
        res.operation = putc;
        res.id = id;
        res.payload = document;
        if (!res.error) {
          res.rev = res.jsonCouchResponse.rev;
          _database.updateLocalStorageObject(
              id, document, rev, _SporranDatabase.updatedc);
          _database.updateAttachmentRevisions(id, rev);

          res.ok = true;
        } else {
          res.rev = null;
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }

      /* Do the put */
      _database.wilt.putDocument(id, document, rev).then(completer);
    });

    return opCompleter.future;
  }

  /// Get a document
  Future<dynamic> get(String id, [String rev]) {
    final Completer<dynamic> opCompleter = Completer<dynamic>();

    if (id == null) {
      return _raiseException(SporranException.getNoDocIdEx);
    }

    /* Check for offline, if so try the get from local storage */
    if (!online) {
      _database.getLocalStorageObject(id).then((dynamic document) {
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.operation = getc;
        res.id = id;
        res.rev = null;
        if (document.isEmpty) {
          res.ok = false;
          res.payload = null;
        } else {
          res.ok = true;
          res.payload = document['payload'];
          res.rev = WiltUserUtils.getDocumentRev(res);
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      });
    } else {
      void completer(dynamic res) {
        /* If Ok update local storage with the document */
        res.operation = getc;
        res.id = id;
        res.localResponse = false;
        if (!res.error) {
          res.rev = WiltUserUtils.getDocumentRev(res.jsonCouchResponse);
          _database.updateLocalStorageObject(
              id, res.jsonCouchResponse, res.rev, _SporranDatabase.updatedc);
          res.ok = true;
          res.payload = res.jsonCouchResponse;
          /**
           * Get the documents attachments and create them locally
           */
          _database.createDocumentAttachments(id, res.payload);
        } else {
          res.ok = false;
          res.payload = null;
          res.rev = null;
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }

      /* Get the document from CouchDb with its attachments */
      _database.wilt.getDocument(id, rev, true).then(completer);
    }

    return opCompleter.future;
  }

  /// Delete a document.
  ///
  /// Revision must be supplied if we are online
  Future<dynamic> delete(String id, [String rev]) {
    final Completer<dynamic> opCompleter = Completer<dynamic>();

    if (id == null) {
      return _raiseException(SporranException.deleteNoDocIdEx);
    }

    /* Remove from Lawndart */
    _database.lawndart.getByKey(id).then((String document) {
      if (document != null) {
        _database.lawndart.removeByKey(id)
            // ignore: missing_return
            .then((_) {
          /* Check for offline, if so add to the pending delete queue
              and return */
          if (!online) {
            _database.addPendingDelete(id, document);
            final dynamic res = JsonObjectLite<dynamic>();
            res.localResponse = true;
            res.operation = deletec;
            res.ok = true;
            res.id = id;
            res.payload = null;
            res.rev = null;
            opCompleter.complete(res);
            if (_clientCompleter != null) {
              _completionResponse = _createCompletionResponse(res);
              _clientCompleter();
            }
            return opCompleter.future;
          } else {
            /* Online, delete from CouchDb */
            void completer(dynamic res) {
              res.operation = deletec;
              res.localResponse = false;
              res.payload = res.jsonCouchResponse;
              res.id = id;
              res.rev = null;
              if (res.error) {
                res.ok = false;
              } else {
                res.ok = true;
                res.rev = res.jsonCouchResponse.rev;
              }

              _database.removePendingDelete(id);
              opCompleter.complete(res);
              if (_clientCompleter != null) {
                _completionResponse = _createCompletionResponse(res);
                _clientCompleter();
              }
            }

            /* Delete the document from CouchDB */
            _database.wilt.deleteDocument(id, rev).then(completer);
          }
        });
      } else {
        /* Doesnt exist, return error */
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.operation = deletec;
        res.id = id;
        res.payload = null;
        res.rev = null;
        res.ok = false;
        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }
    });

    return opCompleter.future;
  }

  /// Put attachment
  ///
  /// If the revision is supplied the attachment to the document
  /// will be updated, otherwise the attachment will be created, along with
  /// the document if needed.
  ///
  /// The JsonObjectLite attachment parameter must contain the following :-
  ///
  /// String attachmentName
  /// String rev - maybe '', see above
  /// String contentType - mime type in the form 'image/png'
  /// String payload - stringified binary blob
  Future<dynamic> putAttachment(String id, dynamic attachment) {
    final Completer<dynamic> opCompleter = Completer<dynamic>();

    if (id == null) {
      return _raiseException(SporranException.putAttNoDocIdEx);
    }

    if (attachment == null) {
      return _raiseException(SporranException.putAttNoAttEx);
    }

    /* Update LawnDart */
    final String key = '$id-${attachment.attachmentName}-'
        '${_SporranDatabase.attachmentMarkerc}';
    _database
        .updateLocalStorageObject(
            key, attachment, attachment.rev, _SporranDatabase.notUpdatedc)
        // ignore: missing_return
        .then((_) {
      /* If we are offline just return */
      if (!online) {
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.operation = putAttachmentc;
        res.ok = true;
        res.payload = attachment;
        res.id = id;
        res.rev = null;
        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
        return opCompleter.future;
      }

      /* Complete locally, then boomerang to the client */
      void completer(dynamic res) {
        /* If success, mark the update as UPDATED in local storage */
        res.ok = false;
        res.localResponse = false;
        res.id = id;
        res.operation = putAttachmentc;
        res.rev = null;
        res.payload = null;

        if (!res.error) {
          final dynamic newAttachment =
              JsonObjectLite<dynamic>.fromJsonString(_mapToJson(attachment));
          newAttachment.contentType = attachment.contentType;
          newAttachment.payload = attachment.payload;
          newAttachment.attachmentName = attachment.attachmentName;
          res.payload = newAttachment;
          res.rev = res.jsonCouchResponse.rev;
          newAttachment.rev = res.jsonCouchResponse.rev;
          _database.updateLocalStorageObject(key, newAttachment,
              res.jsonCouchResponse.rev, _SporranDatabase.updatedc);
          _database.updateAttachmentRevisions(id, res.jsonCouchResponse.rev);
          res.ok = true;
        }
        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }

      /* Do the create */
      if (attachment.rev == '') {
        _database.wilt
            .createAttachment(id, attachment.attachmentName, attachment.rev,
                attachment.contentType, attachment.payload)
            .then(completer);
      } else {
        _database.wilt
            .updateAttachment(id, attachment.attachmentName, attachment.rev,
                attachment.contentType, attachment.payload)
            .then(completer);
      }
    });

    return opCompleter.future;
  }

  /// Delete an attachment.
  /// Revision can be null if offline
  Future<dynamic> deleteAttachment(
      String id, String attachmentName, String rev) {
    final Completer<dynamic> opCompleter = Completer<dynamic>();
    final String key =
        '$id-$attachmentName-${_SporranDatabase.attachmentMarkerc}';

    if (id == null) {
      return _raiseException(SporranException.deleteAttNoDocIdEx);
    }

    if (attachmentName == null) {
      return _raiseException(SporranException.deleteAttNoAttNameEx);
    }

    if (online && (rev == null)) {
      return _raiseException(SporranException.deleteAttNoRevEx);
    }

    /* Remove from Lawndart */
    _database.lawndart.getByKey(key).then((dynamic document) {
      if (document != null) {
        _database.lawndart.removeByKey(key)
            // ignore: missing_return
            .then((_) {
          /* Check for offline, if so add to the pending delete
              queue and return */
          if (!online) {
            _database.addPendingDelete(key, document);
            final dynamic res = JsonObjectLite<dynamic>();
            res.localResponse = true;
            res.operation = deleteAttachmentc;
            res.ok = true;
            res.id = id;
            res.payload = null;
            res.rev = null;
            opCompleter.complete(res);
            if (_clientCompleter != null) {
              _completionResponse = _createCompletionResponse(res);
              _clientCompleter();
            }
            return opCompleter.future;
          } else {
            /* Online, delete from CouchDb */
            void completer(dynamic res) {
              res.operation = deleteAttachmentc;
              res.localResponse = false;
              res.payload = res.jsonCouchResponse;
              res.id = id;
              res.rev = null;
              if (res.error) {
                res.ok = false;
              } else {
                res.ok = true;
                res.rev = res.jsonCouchResponse.rev;
              }
              _database.removePendingDelete(key);
              opCompleter.complete(res);
              if (_clientCompleter != null) {
                _completionResponse = _createCompletionResponse(res);
                _clientCompleter();
              }
            }

            /* Delete the attachment from CouchDB */
            _database.wilt
                .deleteAttachment(id, attachmentName, rev)
                .then(completer);
          }
        });
      } else {
        /* Doesnt exist, return error */
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.operation = deleteAttachmentc;
        res.id = id;
        res.payload = null;
        res.rev = null;
        res.ok = false;
        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }
    });

    return opCompleter.future;
  }

  /// Get an attachment
  Future<dynamic> getAttachment(String id, String attachmentName) {
    final Completer<dynamic> opCompleter = Completer<dynamic>();
    final String key =
        '$id-$attachmentName-${_SporranDatabase.attachmentMarkerc}';

    if (id == null) {
      return _raiseException(SporranException.getAttNoDocIdEx);
    }

    if (attachmentName == null) {
      return _raiseException(SporranException.getAttNoAttNameEx);
    }

    /* Check for offline, if so try the get from local storage */
    if (!online) {
      _database.getLocalStorageObject(key).then((dynamic document) {
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.id = id;
        res.rev = null;
        res.operation = getAttachmentc;
        if (document.isEmpty) {
          res.ok = false;
          res.payload = null;
        } else {
          res.ok = true;
          res.payload = document;
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
        return opCompleter.future;
      });
    } else {
      void completer(dynamic res) {
        /* If Ok update local storage with the attachment */
        res.operation = getAttachmentc;
        res.id = id;
        res.localResponse = false;
        res.rev = null;

        if (!res.error) {
          final dynamic successResponse = res.jsonCouchResponse;

          res.ok = true;
          final dynamic attachment = JsonObjectLite<dynamic>();
          attachment.attachmentName = attachmentName;
          attachment.contentType = successResponse.contentType;
          attachment.payload = res.responseText;
          attachment.rev = res.rev;
          res.payload = attachment;

          _database.updateLocalStorageObject(
              key, attachment, res.rev, _SporranDatabase.updatedc);
        } else {
          res.ok = false;
          res.payload = null;
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }

      /* Get the attachment from CouchDb */
      _database.wilt.getAttachment(id, attachmentName).then(completer);
    }

    return opCompleter.future;
  }

  /// Bulk document create.
  ///
  /// docList is a map of documents with their keys
  Future<dynamic> bulkCreate(Map<String, JsonObjectLite<dynamic>> docList) {
    final Completer<dynamic> opCompleter = Completer<dynamic>();

    if (docList == null) {
      return _raiseException(SporranException.bulkCreateNoDocListEx);
    }

    /* Futures list for LawnDart update */
    final List<Future<dynamic>> updateList = <Future<dynamic>>[];

    /* Update LawnDart */
    docList.forEach((dynamic key, dynamic document) {
      updateList.add(_database.updateLocalStorageObject(
          key, document, null, _SporranDatabase.notUpdatedc));
    });

    /* Wait for Lawndart */
    Future.wait(updateList)
        // ignore: missing_return
        .then((_) {
      /* If we are offline just return */
      if (!online) {
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.operation = bulkCreatec;
        res.ok = true;
        res.payload = docList;
        res.id = null;
        res.rev = null;
        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
        return opCompleter.future;
      }

      /* Complete locally, then boomerang to the client */
      void completer(dynamic res) {
        /* If success, mark the update as UPDATED in local storage */
        res.ok = false;
        res.localResponse = false;
        res.operation = bulkCreatec;
        res.id = null;
        res.payload = docList;
        res.rev = null;
        if (!res.error) {
          /* Get the revisions for the updates */
          final JsonObjectLite<dynamic> couchResp = res.jsonCouchResponse;
          final List<JsonObjectLite<dynamic>> revisions =
              <JsonObjectLite<dynamic>>[];
          final Map<String, String> revisionsMap = <String, String>{};

          for (final dynamic resp in couchResp.toList()) {
            try {
              revisions.add(resp);
              revisionsMap[resp.id] = resp.rev;
            } on Exception {
              revisions.add(null);
            }
          }
          res.rev = revisions;

          /* Update the documents */
          docList.forEach((dynamic key, dynamic document) {
            _database.updateLocalStorageObject(
                key, document, revisionsMap[key], _SporranDatabase.updatedc);
          });

          res.ok = true;
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }

      /* Prepare the documents */
      final List<String> documentList = <String>[];
      docList.forEach((dynamic key, dynamic document) {
        final String docString = WiltUserUtils.addDocumentId(document, key);
        documentList.add(docString);
      });

      final String docs = WiltUserUtils.createBulkInsertString(documentList);

      /* Do the bulk create*/
      _database.wilt.bulkString(docs).then(completer);
    });

    return opCompleter.future;
  }

  /// Get all documents.
  ///
  /// The parameters should be self explanatory and are addative.
  ///
  /// In offline mode only the keys parameter is respected.
  /// The includeDocs parameter is also forced to true.
  Future<JsonObjectLite<dynamic>> getAllDocs(
      {bool includeDocs = false,
      int limit,
      String startKey,
      String endKey,
      List<String> keys,
      bool descending = false}) {
    final Completer<JsonObjectLite<dynamic>> opCompleter =
        Completer<JsonObjectLite<dynamic>>();

    /* Check for offline, if so try the get from local storage */
    if (!online) {
      if (keys == null) {
        /* Get all the keys from Lawndart */
        _database.lawndart.keys().toList().then((dynamic keyList) {
          /* Only return documents */
          final List<String> docList = <String>[];
          keyList.forEach((dynamic key) {
            final List<String> temp = key.split('-');
            if ((temp.length == 3) &&
                (temp[2] == _SporranDatabase.attachmentMarkerc)) {
              /* Attachment, discard the key */

            } else {
              docList.add(key);
            }
          });

          _database.getLocalStorageObjects(docList).then((dynamic documents) {
            final dynamic res = JsonObjectLite<dynamic>();
            res.localResponse = true;
            res.operation = getAllDocsc;
            res.id = null;
            res.rev = null;
            if (documents == null) {
              res.ok = false;
              res.payload = null;
            } else {
              res.ok = true;
              res.payload = documents;
              res.totalRows = documents.length;
              res.keyList = documents.keys.toList();
            }

            opCompleter.complete(res);
            if (_clientCompleter != null) {
              _completionResponse = _createCompletionResponse(res);
              _clientCompleter();
            }
          });
        });
      } else {
        _database.getLocalStorageObjects(keys).then((dynamic documents) {
          final dynamic res = JsonObjectLite<dynamic>();
          res.localResponse = true;
          res.operation = getAllDocsc;
          res.id = null;
          res.rev = null;
          if (documents == null) {
            res.ok = false;
            res.payload = null;
          } else {
            res.ok = true;
            res.payload = documents;
            res.totalRows = documents.length;
            res.keyList = documents.keys.toList();
          }

          opCompleter.complete(res);
          if (_clientCompleter != null) {
            _completionResponse = _createCompletionResponse(res);
            _clientCompleter();
          }
        });
      }
    } else {
      void completer(dynamic res) {
        /* If Ok update local storage with the document */
        res.operation = getAllDocsc;
        res.id = null;
        res.rev = null;
        res.localResponse = false;
        if (!res.error) {
          res.ok = true;
          res.payload = res.jsonCouchResponse;
        } else {
          res.localResponse = false;
          res.ok = false;
          res.payload = null;
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }

      /* Get the document from CouchDb */
      _database.wilt
          .getAllDocs(
              includeDocs: includeDocs,
              limit: limit,
              startKey: startKey,
              endKey: endKey,
              keys: keys,
              descending: descending)
          .then(completer);
    }

    return opCompleter.future;
  }

  /// Get information about the database.
  ///
  /// When offline the a list of the keys in the Lawndart database are returned,
  /// otherwise a response for CouchDb is returned.
  Future<JsonObjectLite<dynamic>> getDatabaseInfo() {
    final Completer<JsonObjectLite<dynamic>> opCompleter =
        Completer<JsonObjectLite<dynamic>>();

    if (!online) {
      _database.lawndart.keys().toList().then((List<dynamic> keys) {
        final dynamic res = JsonObjectLite<dynamic>();
        res.localResponse = true;
        res.operation = dbInfoc;
        res.id = null;
        res.rev = null;
        res.payload = keys;
        res.ok = true;
        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      });
    } else {
      void completer(dynamic res) {
        /* If Ok update local storage with the database info */
        res.operation = dbInfoc;
        res.id = null;
        res.rev = null;
        res.localResponse = false;
        if (!res.error) {
          res.ok = true;
          res.payload = res.jsonCouchResponse;
        } else {
          res.localResponse = false;
          res.ok = false;
          res.payload = null;
        }

        opCompleter.complete(res);
        if (_clientCompleter != null) {
          _completionResponse = _createCompletionResponse(res);
          _clientCompleter();
        }
      }

      /* Get the database information from CouchDb */
      _database.wilt.getDatabaseInfo().then(completer);
    }

    return opCompleter.future;
  }

  /// Synchronise local storage and CouchDb when we come online or on demand.
  ///
  /// Note we don't check for failures in this, there is nothing we
  /// can really do if we say get a conflict error or a not exists error
  /// on an update or delete.
  ///
  /// For updates, if applied successfully we wait for the change
  /// notification to arrive to mark the update as UPDATED. Note if these
  /// are switched off sync may be lost with Couch.
  void sync() {
    /* Only if we are online */
    if (!online) {
      return;
    }
    _database.sync();
  }

  /// Login
  ///
  /// Allows log in credentials to be changed if needed.
  void login(String user, String password) {
    if (user == null || password == null) {
      throw SporranException(SporranException.invalidLoginCredsEx);
    }

    _database.login(user, password);
  }

  /// Serialize a map to a JSON string
  static String _mapToJson(dynamic map) {
    if (map is String) {
      try {
        final dynamic res = json.decode(map);
        if (res != null) {
          return map;
        } else {
          return null;
        }
      } on Exception {
        return null;
      }
    }
    return json.encode(map);
  }
}
