;;; -*- show-trailing-whitespace: t; indent-tabs: nil -*-

;;; Copyright (c) 2007 Ivan Shvedunov. All rights reserved.
;;; Copyright (c) 2007 David Lichteblau. All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :xpath)

;; function library

(define-extension xpath "" "Standard XPath functions")

(defun xf-equal (u v) ;; FIXME: rm; use compare-values in tests
  #'(lambda (context)
      (compare-values 'equal
                      (funcall u context)
                      (funcall v context))))

(defun xf-and (exprs)
  (cond ((null exprs) t)
        ((null (rest exprs))
         (let ((first (first exprs)))
           #'(lambda (context)
               (boolean-value (funcall first context)))))
        (t
         (let ((first (first exprs))
               (rest (xf-and (rest exprs))))
           #'(lambda (context)
               (and (boolean-value (funcall first context))
                    (funcall rest context)))))))

(defun xf-or (exprs)
  (cond ((null exprs) nil)
        ((null (rest exprs))
         (let ((first (first exprs)))
           #'(lambda (context)
               (boolean-value (funcall first context)))))
        (t
         (let ((first (first exprs))
               (rest (xf-and (rest exprs))))
           #'(lambda (context)
               (or (boolean-value (funcall first context))
                   (funcall rest context)))))))

(define-xpath-function/eager xpath := (a b) (compare-values 'equal a b))

(define-xpath-function/eager xpath :/= (a b) (not (compare-values 'equal a b)))

(define-xpath-function/eager xpath :< (a b) (compare-values '< a b))

(define-xpath-function/eager xpath :> (a b) (compare-values '> a b))

(define-xpath-function/eager xpath :<= (a b) (compare-values '<= a b))

(define-xpath-function/eager xpath :>= (a b) (compare-values '>= a b))

;; boolean functions

(define-xpath-function/lazy xpath :and (&rest exprs) (xf-and exprs))

(define-xpath-function/lazy xpath :or (&rest exprs) (xf-or exprs))

(define-xpath-function/single-type xpath :not boolean (a) (not a))

(define-xpath-function/eager xpath :true () t)

(define-xpath-function/eager xpath :false () nil)

(define-xpath-function/single-type xpath :boolean boolean (value) value)

;; node-set functions

(define-xpath-function/eager xpath :position () (context-position context))

(define-xpath-function/eager xpath :last () (context-size context))

(define-xpath-function/single-type xpath :count node-set (node-set)
  (pipe-length (pipe-of node-set)))

(define-xpath-function/single-type xpath :local-name node-set (&optional node-set)
  (cond ((null node-set) (xpath-protocol:local-name (context-node context))) ;; FIXME: root?
        ((pipe-empty-p (pipe-of node-set)) "")
        (t (xpath-protocol:local-name (textually-first-node node-set)))))

(define-xpath-function/single-type xpath :name node-set (&optional node-set)
  (cond ((null node-set)
	 (xpath-protocol:qualified-name (context-node context)))
        ((pipe-empty-p (pipe-of node-set)) "")
        (t (xpath-protocol:qualified-name (textually-first-node node-set)))))

(define-xpath-function/single-type xpath :namespace-uri node-set (&optional node-set)
  (cond ((null node-set)
	 (xpath-protocol:namespace-uri (context-node context)))
        ((pipe-empty-p (pipe-of node-set)) "")
        (t (xpath-protocol:namespace-uri (textually-first-node node-set)))))

;; helper function for the | operator:
(define-xpath-function/eager xpath :union (&rest node-sets)
  ;; Need to sort on document order, see copy_copy47, copy_copy48
  ;; It's what users would want anyway.
  (make-node-set
   (sort-pipe (mappend-pipe #'pipe-of (mapcar #'node-set-value node-sets)))
   :document-order))

(define-xpath-function/single-type xpath :sum node-set (node-set)
  (let ((sum 0))
    (block nil
      (enumerate (pipe-of node-set)
		 :key #'(lambda (node)
			  (let ((num (number-value node)))
			    (if (nan-p num)
				(return :nan)
				(setf sum (xnum-+ sum num))))))
      sum)))

(define-xpath-function/eager xpath :id (object)
  (labels ((get-by-ids (ids)
	     (let ((ids (trim (string-value ids))))
	       (if (zerop (length ids))
		   empty-pipe
		   (filter-pipe (complement #'null)
				(map-pipe #'(lambda (id)
					      (xpath-protocol:get-element-by-id
					       (context-node context) id))
					  (cl-ppcre:split "\\s+" ids)))))))
    (make-node-set
     (sort-pipe
      (if (node-set-p object)
	  (mappend-pipe #'get-by-ids (pipe-of object))
	  (get-by-ids object))))))

;; string functions

(define-xpath-function/lazy xpath :string (&optional string)
  (if string
      (lambda (ctx)
	(string-value (funcall string ctx)))
      (lambda (ctx)
	(string-value (context-node ctx)))))

(define-xpath-function/single-type xpath :concat string (&rest strings)
  (reduce #'concat strings))

(define-xpath-function/single-type xpath :contains string (needle haystack)
  (and (search needle haystack) t))

(define-xpath-function/eager xpath :substring (string start &optional (len nil len-p))
  (let* ((string (string-value string))
         (start (xnum-round (number-value start)))
         (end (if len-p
                  (xnum-+ start (xnum-round (number-value len)))
                  (1+ (length string)))))
    (if (or (nan-p start)
            (nan-p end)
            (compare-numbers '> start end)
            (compare-numbers '> start (length string))
            (compare-numbers '< end 1))
        ""
        (subseq string
                (1- (if (inf-p start) 1 (max 1 start)))
                (1- (if (inf-p end)
                        (1+ (length string))
                        (min end (1+ (length string)))))))))

(define-xpath-function/eager xpath :starts-with (string prefix)
  (let* ((string (string-value string))
         (prefix (string-value prefix))
	 (i (mismatch string prefix)))
    (and (or (null i)
	     (eql i (length prefix)))
	 t)))

;; FIXME: corner case: empty substring?
;; [looks correct to me.  XPath 2.0 agrees that the empty string is
;; returned if the second argument is the empty string. --dfl]
(define-xpath-function/single-type xpath :substring-before string (string substring)
  (let ((p (search substring string)))
    (if (null p)
        ""
        (subseq string 0 p))))

;; FIXME: corner case: empty substring?
;; [looks correct to me.  XPath 2.0 agrees that the first argument is
;; returned if the second argument is the empty string. --dfl]
(define-xpath-function/single-type xpath :substring-after string (string substring)
  (let ((p (search substring string)))
    (if (null p)
        ""
        (subseq string (+ p (length substring))))))

(define-xpath-function/lazy xpath :string-length (&optional string)
  (if string
      (lambda (ctx)
	(length (string-value (funcall string ctx))))
      (lambda (ctx)
	(length (string-value (context-node ctx))))))

(define-xpath-function/lazy xpath :normalize-space (&optional string)
  (lambda (ctx)
    (let ((string
	   (string-value (if string
			     (funcall string ctx)
			     (context-node ctx)))))
      (cl-ppcre::regex-replace-all "\\s+" (trim string) " "))))

(define-xpath-function/single-type xpath :translate string (string from to)
  (map 'string
       (lambda (c)
	 (let ((i (position c from)))
	   (if i
	       (elt to i)
	       c)))
       string))

;; number functions

(define-xpath-function/lazy xpath :number (&optional string)
  (if string
      (lambda (ctx)
	(number-value (funcall string ctx)))
      (lambda (ctx)
	(number-value (context-node ctx)))))

(define-xpath-function/single-type xpath :floor number (value)
  (xnum-floor value))

(define-xpath-function/single-type xpath :round number (value)
  (xnum-round value))

(define-xpath-function/single-type xpath :ceiling number (value)
  (xnum-ceiling value))

(macrolet ((numop (op lisp-op)
             `(define-xpath-function/single-type xpath ,op number (a b) (,lisp-op a b))))
  (numop :+ xnum-+)
  (numop :* xnum-*)
  (numop :/ xnum-/)
  (numop :mod xnum-mod))

(define-xpath-function/eager xpath :- (a &optional (b nil b-p))
  (if b-p
      (xnum-- (number-value a) (number-value b))
      (xnum-- (number-value a))))
