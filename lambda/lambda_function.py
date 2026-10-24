"""Serves the CV from the private S3 bucket through a Lambda function URL.

The bucket and prefix come from the BUCKET and PREFIX environment variables.
Permissions come from the execution role cv-lambda-role-23l-3037 (no keys).
"""
import base64
import json
import os
import time

import boto3

s3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ["PREFIX"].rstrip("/") + "/"

# request path -> (file name under PREFIX, content type)
ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css"),
    "/cv.pdf": ("cv.pdf", "application/pdf"),
}

NOT_FOUND_PAGE = (
    "<!DOCTYPE html><html><head><title>404 Not Found</title></head>"
    "<body><h1>404 - Not Found</h1><p>Try <a href=\"/\">the CV</a>.</p></body></html>"
)


def lambda_handler(event, context):
    start = time.time()
    path = event.get("rawPath") or "/"

    try:
        response = build_response(path, context.function_name)
    except Exception as exc:  # e.g. S3 AccessDenied or missing object
        print(json.dumps({"error": str(exc), "path": path}))
        response = {
            "statusCode": 500,
            "headers": {"Content-Type": "text/plain"},
            "body": "Internal error",
        }

    # One JSON line per request, read later with: aws logs tail
    print(json.dumps({
        "fn": context.function_name,
        "path": path,
        "status": response["statusCode"],
        "ms": round((time.time() - start) * 1000),
    }))
    return response


def build_response(path, function_name):
    if path not in ROUTES:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "text/html; charset=utf-8"},
            "body": NOT_FOUND_PAGE,
        }

    filename, content_type = ROUTES[path]
    data = s3.get_object(Bucket=BUCKET, Key=PREFIX + filename)["Body"].read()
    headers = {"Content-Type": content_type}

    if filename == "cv.pdf":
        # Binary: the function URL only carries text, so send base64 and set the flag.
        return {
            "statusCode": 200,
            "headers": headers,
            "body": base64.b64encode(data).decode("ascii"),
            "isBase64Encoded": True,
        }

    body = data.decode("utf-8")
    if filename == "index.html":
        body = body.replace("{{HOSTED_ON}}", "Lambda " + function_name)
        headers["Cache-Control"] = "public, max-age=60"

    return {"statusCode": 200, "headers": headers, "body": body, "isBase64Encoded": False}
