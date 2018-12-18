#|

Chicken Scheme bindings for lmdb, fast key value database.
Modified for Chicken Scheme by Ivan Raikov and Caolan McMahon.

Based on lmdb wrapper for LambdaNative - a cross-platform Scheme
framework Copyright (c) 2009-2015, University of British Columbia All
rights reserved.

Redistribution and use in source and binary forms, with or
without modification, are permitted provided that the
following conditions are met:

* Redistributions of source code must retain the above
copyright notice, this list of conditions and the following
disclaimer.

* Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following
disclaimer in the documentation and/or other materials
provided with the distribution.

* Neither the name of the University of British Columbia nor
the names of its contributors may be used to endorse or
promote products derived from this software without specific
prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
|#

(module lmdb-ht

        (
         debuglevel
         make-context
         destroy-context!
         db-init
         db-open
         db-close
	 db-max-key-size
         db-begin
         db-end
	 db-abort
         db-write
         db-read
         db-key-len
         db-value-len
         db-key
         db-value
         db-index-first
         db-index-next
         db-delete
         db-delete-database
         db-set!
         db-ref
         db-count
         db-keys
         db-values
         db-fold
         db-for-each
         hash-table->db
         db->hash-table
         )

	(import scheme (chicken base) (chicken foreign) (chicken blob)
                (only (chicken format) printf fprintf sprintf)
                (only (chicken pathname) make-pathname)
                (only (chicken file) create-directory delete-directory
                      delete-file file-exists?)
                (chicken condition) 
                srfi-69  (prefix rabbit rabbit:))
        
	;(import scheme (chicken base) (chicken foreign) (chicken blob) 
                ;
                ;(only (chicken files) make-pathname  create-directory delete-directory)
         ;       

        (define debuglevel (make-parameter 0))
        (define (logger level . x)
          (if (>= (debuglevel) level) (apply printf x)))


	(define error-code-string
	  (foreign-lambda c-string "mdb_strerror" int))

	(define code-symbol-map
	  (alist->hash-table
	   `((,(foreign-value "MDB_KEYEXIST" int) . mdb-keyexist)
	     (,(foreign-value "MDB_NOTFOUND" int) . mdb-notfound)
	     (,(foreign-value "MDB_PAGE_NOTFOUND" int) . mdb-page-notfound)
	     (,(foreign-value "MDB_CORRUPTED" int) . mdb-corrupted)
	     (,(foreign-value "MDB_PANIC" int) . mdb-panic)
	     (,(foreign-value "MDB_VERSION_MISMATCH" int) . mdb-version-mismatch)
	     (,(foreign-value "MDB_INVALID" int) . mdb-invalid)
	     (,(foreign-value "MDB_MAP_FULL" int) . mdb-map-full)
             (,(foreign-value "MDB_DBS_FULL" int) . mdb-dbs-full)
	     (,(foreign-value "MDB_READERS_FULL" int) . mdb-readers-full)
	     (,(foreign-value "MDB_TLS_FULL" int) . mdb-tls-full)
	     (,(foreign-value "MDB_TXN_FULL" int) . mdb-txn-full)
	     (,(foreign-value "MDB_CURSOR_FULL" int) . mdb-cursor-full)
	     (,(foreign-value "MDB_PAGE_FULL" int) . mdb-page-full)
	     (,(foreign-value "MDB_MAP_RESIZED" int) . mdb-map-resized)
	     (,(foreign-value "MDB_INCOMPATIBLE" int) . mdb-incompatible)
	     (,(foreign-value "MDB_BAD_RSLOT" int) . mdb-bad-rslot)
	     (,(foreign-value "MDB_BAD_TXN" int) . mdb-bad-txn)
	     (,(foreign-value "MDB_BAD_VALSIZE" int) . mdb-bad-valsize)
	     (,(foreign-value "MDB_BAD_DBI" int) . mdb-bad-dbi))
	   hash: number-hash
	   test: =
	   size: 20))
	
	(define (error-code-symbol code)
	  (hash-table-ref/default code-symbol-map code 'unknown))
	
	(define-external (chicken_lmdb_condition (int code)) scheme-object
	  (make-composite-condition
	   (make-property-condition 'exn 'message (error-code-string code))
	   (make-property-condition 'lmdb)
	   (make-property-condition (error-code-symbol code))))
	
#>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include <lmdb.h>

#define C_bytevector_length(x)      (C_header_size(x))

static void chicken_Panic (C_char *) C_noret;
static void chicken_Panic (C_char *msg)
{
  C_word *a = C_alloc (C_SIZEOF_STRING (strlen (msg)));
  C_word scmmsg = C_string2 (&a, msg);
  C_halt (scmmsg);
  exit (5); /* should never get here */
}

static void chicken_ThrowException(C_word value) C_noret;
static void chicken_ThrowException(C_word value)
{
  char *aborthook = C_text("\003sysabort");

  C_word *a = C_alloc(C_SIZEOF_STRING(strlen(aborthook)));
  C_word abort = C_intern2(&a, aborthook);

  abort = C_block_item(abort, 0);
  if (C_immediatep(abort))
    chicken_Panic(C_text("`##sys#abort' is not defined"));

#if defined(C_BINARY_VERSION) && (C_BINARY_VERSION >= 8)
  C_word rval[3] = { abort, C_SCHEME_UNDEFINED, value };
  C_do_apply(3, rval);
#else
  C_save(value);
  C_do_apply(1, abort, C_SCHEME_UNDEFINED);
#endif
}

// see define-external
C_word chicken_lmdb_condition(int code);

void chicken_lmdb_exception (int code) 
{
  chicken_ThrowException(chicken_lmdb_condition(code));
}

struct _mdb {
  MDB_env *env;
  MDB_dbi dbi;
  MDB_val key, value;
  MDB_txn *txn;
  MDB_cursor *cursor;
  char *dbname;
};

struct _mdb *_mdb_init(char *fname, int maxdbs, size_t mapsize)
{
  int rc;
  struct _mdb *m = (struct _mdb *)malloc(sizeof(struct _mdb));
  if ((rc = mdb_env_create(&m->env)) != 0) 
  {
     chicken_lmdb_exception (rc);
  }
  if (maxdbs > 0) 
  {
     if ((rc = mdb_env_set_maxdbs(m->env, maxdbs)) != 0)
     {
        chicken_lmdb_exception (rc);
     }
  }
  if (mapsize > 0) 
  {
     if ((rc = mdb_env_set_mapsize(m->env, mapsize)) != 0)
     {
        chicken_lmdb_exception (rc);
     }
  }
  if ((rc = mdb_env_open(m->env, fname, 0, 0664)) != 0)
  {
     chicken_lmdb_exception (rc);
  }
  m->cursor=NULL;
  m->dbname=NULL;
  return m;
}


int _mdb_begin(struct _mdb *m, char *dbname)
{
  int rc, n;
  if ((rc = mdb_txn_begin(m->env, NULL, 0, &(m->txn))) != 0)
  {
     chicken_lmdb_exception (rc);
  }
  if ((rc = mdb_open(m->txn, dbname, MDB_CREATE, &m->dbi)) != 0)
  {
     chicken_lmdb_exception (rc);
  }
  m->cursor=NULL;
  if (dbname != NULL)
  {
     n = strnlen(dbname,256);
     m->dbname = malloc(n+1);
     strncpy(m->dbname, dbname, n);
     m->dbname[n] = 0;
  }
  return rc;
}


void _mdb_end(struct _mdb *m)
{
  int rc;
  if ((rc = mdb_txn_commit(m->txn)) != 0) 
  {
     chicken_lmdb_exception (rc);
  }
  mdb_close(m->env, m->dbi);
}

void _mdb_abort(struct _mdb *m)
{
  mdb_txn_abort(m->txn);
  mdb_close(m->env, m->dbi);
}


int _mdb_write(struct _mdb *m, unsigned char *k, int klen, unsigned char *v, int vlen)
{
  int rc;
  m->key.mv_size = klen;
  m->key.mv_data = k;
  m->value.mv_size = vlen;
  m->value.mv_data = v;
  if ((rc = mdb_put(m->txn, m->dbi, &(m->key), &(m->value), 0)) != 0)
  {
     switch (rc) 
     {
      case MDB_BAD_TXN:
        mdb_txn_abort(m->txn);
        mdb_close(m->env, m->dbi);
        assert ((rc = _mdb_begin(m, m->dbname)) == 0);
        if ((rc = mdb_put(m->txn, m->dbi, &(m->key), &(m->value), 0)) != 0)
        {
           chicken_lmdb_exception (rc);
        };
        break;
      default:
        mdb_txn_commit(m->txn);
        mdb_close(m->env, m->dbi);
        chicken_lmdb_exception (rc);
     }
  }
  return rc;
}

int _mdb_read(struct _mdb *m, unsigned char *k, int klen)
{
  int rc;
  m->key.mv_size = klen;
  m->key.mv_data = k;
  if ((rc = mdb_get(m->txn,m->dbi,&m->key, &m->value)) != 0)
  {
     chicken_lmdb_exception (rc);
  }
  return rc;
}

int _mdb_index_first(struct _mdb *m)
{
  int rc;
  if (m->cursor) { mdb_cursor_close(m->cursor); }
  if ((rc = mdb_cursor_open(m->txn, m->dbi, &(m->cursor))) != 0)
  {
     chicken_lmdb_exception (rc);
  } else 
    if ((rc = mdb_cursor_get(m->cursor, &(m->key), &(m->value), MDB_FIRST)) != 0)
    {
     chicken_lmdb_exception (rc);
    }
  return rc;
}

int _mdb_index_next(struct _mdb *m)
{
  int rc;
  rc = mdb_cursor_get(m->cursor, &(m->key), &(m->value), MDB_NEXT);
  return rc;
}

int _mdb_del(struct _mdb *m, unsigned char *k, int klen)
{
  int rc;
  m->key.mv_size = klen;
  m->key.mv_data = k;
  rc = mdb_del(m->txn, m->dbi, &m->key, &m->value);
  if (!rc) { rc = mdb_txn_commit(m->txn); }
  return rc;
}

int _mdb_key_len(struct _mdb *m) { return m->key.mv_size; }
void _mdb_key(struct _mdb *m, unsigned char *buf) { memcpy(buf,m->key.mv_data,m->key.mv_size); }
int _mdb_value_len(struct _mdb *m) { return m->value.mv_size; }
void _mdb_value(struct _mdb *m, unsigned char *buf) { memcpy(buf,m->value.mv_data,m->value.mv_size); }

void _mdb_close(struct _mdb *m)
{
  mdb_env_close(m->env);
  if (m->dbname != NULL)
  {
     free(m->dbname);
     m->dbname = NULL;
  }
  free(m);
}

int _mdb_count(struct _mdb *m)
{
  MDB_stat s;
  int rc;
  rc = mdb_stat(m->txn, m->dbi, &s);
  return s.ms_entries;
}

int _mdb_stats(struct _mdb *m)
{
  MDB_stat s;
  int rc;
  rc = mdb_stat(m->txn, m->dbi, &s);
  return s.ms_entries;
}

<#

;; encode/decode context

(define make-context rabbit:make-context)

(define destroy-context! rabbit:destroy-context!)

(define (db-encoder keyctx)
  (lambda (obj) (rabbit:encode! keyctx obj)))

(define (db-decoder keyctx)
  (lambda (u8v) 
    (condition-case 
     (rabbit:decode! keyctx u8v)
     [var () (begin (warning "db-decoder" "failed to deserialize: " var)
                    'LMDB_FAILURE)])
    ))


;; ffi


(define db-init0 (foreign-safe-lambda* 
                    nonnull-c-pointer ((nonnull-c-string fname) (int maxdbs) (size_t mapsize))
                    "C_return (_mdb_init (fname,maxdbs,mapsize));"))
(define (db-init fname #!key (maxdbs 0) (mapsize 0))
  (db-init0 fname maxdbs mapsize))

(define c-lmdb-begin (foreign-safe-lambda* 
                      int ((nonnull-c-pointer m) (c-string dbname))
                      "C_return(_mdb_begin (m, dbname));"))

(define c-lmdb-end (foreign-safe-lambda* 
                    void ((nonnull-c-pointer m))
                    "_mdb_end (m);"))

(define c-lmdb-abort (foreign-safe-lambda* 
			 void ((nonnull-c-pointer m))
		       "_mdb_abort (m);"))

(define c-lmdb-close (foreign-safe-lambda* 
                        void ((nonnull-c-pointer m))
                        "_mdb_close (m);"))

(define c-lmdb-max-key-size
  (foreign-lambda* int (((nonnull-c-pointer (struct _mdb)) m))
    "int size = mdb_env_get_maxkeysize(m->env);
     C_return(size);"))

(define (db-write m key val) 
  (logger 3 "db-write: ~A ~A = ~A~%" m key val)
  ((foreign-safe-lambda* int ((nonnull-c-pointer m) (scheme-object key) (scheme-object val))
#<<END
     int klen, vlen, result; void* keydata, *valdata;
     C_i_check_bytevector (key);
     C_i_check_bytevector (val);
     klen     = C_bytevector_length(key);
     keydata  = C_c_bytevector (key);
     vlen     = C_bytevector_length(val);
     valdata  = C_c_bytevector (val);
     result   = _mdb_write(m, keydata, klen, valdata, vlen);
     C_return (result);
END
) m key val))


(define (db-read m key) 
  (logger 3 "db-read: ~A~%" key)
  ((foreign-safe-lambda* int ((nonnull-c-pointer m) (scheme-object key))
#<<END
     int klen, result; void* keydata;
     C_i_check_bytevector (key);
     klen     = C_bytevector_length(key);
     keydata  = C_c_bytevector (key);
     result   = _mdb_read(m, keydata, klen);
     C_return (result);
END
) m key))


(define db-key-len (foreign-safe-lambda* 
                    unsigned-int ((nonnull-c-pointer m)) 
                    "C_return (_mdb_key_len (m));"))
(define db-value-len (foreign-safe-lambda* 
                      unsigned-int ((nonnull-c-pointer m)) 
                      "C_return (_mdb_value_len (m));"))

(define db-key (foreign-safe-lambda* 
                  unsigned-int ((nonnull-c-pointer m) (scheme-object buf)) 
                  "_mdb_key (m, C_c_bytevector(buf));"))
(define db-value (foreign-safe-lambda* 
                    unsigned-int ((nonnull-c-pointer m) (scheme-object buf)) 
                    "_mdb_value (m, C_c_bytevector(buf));"))

(define c-lmdb-count (foreign-safe-lambda* 
                      unsigned-int ((nonnull-c-pointer m)) 
                      "C_return (_mdb_count (m));"))

(define db-index-first (foreign-safe-lambda* 
                          unsigned-int ((nonnull-c-pointer m)) 
                          "C_return (_mdb_index_first (m));"))
(define db-index-next (foreign-safe-lambda* 
                         unsigned-int ((nonnull-c-pointer m)) 
                         "C_return (_mdb_index_next (m));"))


;; main interface

(define-record-type lmdb-session
  (make-lmdb-session handler encoder decoder ctx)
  lmdb-session?
  (handler       lmdb-session-handler )
  (encoder       lmdb-session-encoder )
  (decoder       lmdb-session-decoder )
  (ctx           lmdb-session-ctx )
  )


(define (db-delete fname)
  (abort
   (make-property-condition 'exn
    'message "db-delete is deprecated, use db-delete-database instead")))

(define (db-delete-database fname)
  (logger 2 "db-delete-database ~A~%" fname)
  (if (file-exists? fname) (begin
     (delete-file (make-pathname fname "data.mdb"))
     (delete-file (make-pathname fname "lock.mdb"))
     (delete-directory fname)))) 


(define (db-open fname #!key (key #f) (maxdbs 0) (mapsize 0))
  (logger 2 "db-open ~A ~A~%" fname key)
  (let ((ctx (and key (make-context key))))
    (if (not (file-exists? fname)) (create-directory fname))
    (make-lmdb-session
     (db-init fname maxdbs: maxdbs mapsize: mapsize)
     (if (not ctx) identity (db-encoder ctx))
     (if (not ctx) identity (db-decoder ctx)) 
     ctx)))



(define (db-max-key-size s)
  (c-lmdb-max-key-size (lmdb-session-handler s)))

(define (db-begin s #!key (dbname #f))
  (logger 2 "db-begin ~A ~A~%" s dbname)
  (c-lmdb-begin (lmdb-session-handler s) dbname))

(define (db-end s)
  (logger 2 "db-end ~A~%" s)
  (c-lmdb-end (lmdb-session-handler s)))

(define (db-abort s)
  (logger 2 "db-abort ~A~%" s)
  (c-lmdb-abort (lmdb-session-handler s)))

(define (db-set! s key val)
  (logger 2 "db-set! ~A ~A ~A~%" s key val)
  (let* ((lmdb-ptr (lmdb-session-handler s))
         (lmdb-encode (lmdb-session-encoder s))
         (u8key (lmdb-encode key))
         (u8val (lmdb-encode val)))
    (db-write lmdb-ptr u8key u8val)))


(define (db-ref s key)
  (logger 2 "db-ref ~A ~A~%" s key)
  (let* ((m (lmdb-session-handler s))
         (encode (lmdb-session-encoder s))
         (decode (lmdb-session-decoder s))
         (u8key  (encode key))
         (res    (db-read m u8key))
         (vlen   (and (= res 0) (db-value-len m)))
         (u8val  (and vlen (make-blob vlen))))
    (and u8val (begin (db-value m u8val) (decode u8val)))
    ))



(define (db-close s) 
  (logger 2 "db-close ~A~%" s)
  (let ((ctx (lmdb-session-ctx s)))
    (c-lmdb-close (lmdb-session-handler s))
    (if ctx (destroy-context! ctx))))


(define (db-count s)
  (logger 2 "db-count ~A~%" s)
  (c-lmdb-count (lmdb-session-handler s)))


(define (db-get-key s)
  (logger 2 "db-get-key ~A~%" s)
  (let* ((m (lmdb-session-handler s))
         (decode (lmdb-session-decoder s)))
    (let* ((klen (db-key-len m))
           (k (make-blob klen)))
      (db-key m k) 
      (decode k)
      ))
  )

(define (db-keys s)
  (logger 2 "db-keys ~A~%" s)
  (let* ((m (lmdb-session-handler s))
         (decode (lmdb-session-decoder s)))
    (db-index-first m)
    (let loop ((idx (list (db-get-key s))))
      (let ((res (db-index-next m)))
        (if (not (= res 0)) idx
          (let* ((klen (db-key-len m))
                 (k (make-blob klen)))
            (db-key m k) 
            (loop (cons (decode k) idx))
            ))
        ))
    ))

(define (db-get-value s)
  (logger 2 "db-value ~A~%" s)
  (let* ((m (lmdb-session-handler s))
         (decode (lmdb-session-decoder s)))
    (let* ((vlen (db-value-len m))
           (v (make-blob vlen)))
      (db-value m v) 
      (decode v)
      ))
  )


(define (db-values s)
  (logger 2 "db-values ~A~%" s)
  (let* ((m (lmdb-session-handler s))
         (decode (lmdb-session-decoder s)))
    (db-index-first m)
    (let loop ((idx (list (db-get-value s))))
      (let ((res (db-index-next m)))
        (if (not (= res 0)) idx
          (let* ((vlen (db-value-len m))
                 (v (make-blob vlen)))
            (db-value m v) 
            (loop (cons (decode v) idx))
            ))
        ))
    ))


(define (db-fold f init s)
  (logger 2 "db-fold ~A~%" s)
  (let* ((m (lmdb-session-handler s))
         (decode (lmdb-session-decoder s)))
    (db-index-first m)
    (let loop ((ax (let ((k0 (db-get-key s))
                         (v0 (db-get-value s)))
                     (f k0 v0 init))))
      (let ((res (db-index-next m)))
        (if (not (= res 0)) ax
          (let* ((klen (db-key-len m))
                 (k (make-blob klen))
                 (vlen (db-value-len m))
                 (v (make-blob vlen)))
            (db-key m k) 
            (db-value m v) 
            (loop (f (decode k) (decode v) ax))
            ))
        ))
    ))


(define (db-for-each f s)
  (logger 2 "db-for-each ~A~%" s)
  (let* ((m (lmdb-session-handler s))
         (decode (lmdb-session-decoder s)))
    (db-index-first m)
    (let ((k0 (db-get-key s))
          (v0 (db-get-value s)))
      (f k0 v0))
    (let loop ()
      (let ((res (db-index-next m)))
        (if (not (= res 0)) (begin)
          (let* ((klen (db-key-len m))
                 (k (make-blob klen))
                 (vlen (db-value-len m))
                 (v (make-blob vlen)))
            (db-key m k) 
            (db-value m v) 
            (f (decode k) (decode v))
            (loop)
            ))
        ))
    ))


(define (hash-table->db t mfile . key)
  (logger 2 "hash-table->db ~A ~A ~A~%" t mfile key)
  (db-delete-database mfile)
  (let ((s (apply db-open (append (list mfile) key))))
    (hash-table-for-each t (lambda (k v) (db-set! s (string->blob (symbol->string k)) v)))
    (db-close s) #t))


(define (db->hash-table mfile . key)
  (logger 2 "db->hash-table ~A ~A~%" mfile key)
  (if (not (file-exists? mfile)) #f
    (let* ((s (apply db-open (append (list mfile) key)))
           (m (lmdb-session-handler s))
           (decode (lmdb-session-decoder s))
           (t (make-hash-table)))
      (if m 
          (begin
            (db-begin s)
            (db-index-first m) 
            (let* ((klen (db-key-len m))
                   (k (make-blob klen))
                   (vlen (db-value-len m))
                   (v (make-blob vlen)))
              (db-key m k)
              (db-value m v)
              (hash-table-set! t k v))
            (let ((fnl (let loop ()
                         (let* ((res (db-index-next m))
                                (klen (if (= res 0) (db-key-len m) #f))
                                (vlen (if (= res 0) (db-value-len m) #f))
                                (u8val (if vlen (make-blob vlen) #f))
                                (u8key (if klen (make-blob klen) #f))
                                (k (if u8key (begin (db-key m u8key) (decode u8key)) #f))
                                (v (if u8val (begin (db-value m u8val) (decode u8val)) #f)))
                           (if (or (not (= res 0)) (equal? k 'LMDB_FAILURE) (equal? v 'LMDB_FAILURE))
                               t (begin
                                   (hash-table-set! t k v)
                                   (loop)))))))
              (db-end s)
              (db-close s)
              fnl
              ))
          #f))))

)
