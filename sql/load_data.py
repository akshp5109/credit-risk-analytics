"""
load_data.py
-------------
Loads the raw Home Credit Default Risk CSVs into Postgres staging tables.
Run this ONCE before doing any SQL work. After this, all the real work
happens in sql_walkthrough.sql inside your SQL tool.

Setup (one-time):
    pip install pandas sqlalchemy psycopg2-binary
    (MySQL users: pip install pandas sqlalchemy pymysql, and change the
     connection string below as noted)

Before running:
    1. In your SQL tool, run: CREATE DATABASE credit_risk_db;
    2. Update DB_USER / DB_PASS / DATA_DIR below to match your setup.
"""

import pandas as pd
from sqlalchemy import create_engine

# ---------------------------------------------------------------------
# 1. CONNECTION — update these to match your local setup
# ---------------------------------------------------------------------
DB_USER = "postgres"
DB_PASS = "aksh123."
DB_HOST = "localhost"
DB_PORT = "5432"
DB_NAME = "credit_risk_db"

# Postgres connection string:
engine = create_engine(f"postgresql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}")

# MySQL users: comment out the line above and use this instead
# (requires: pip install pymysql)
# engine = create_engine(f"mysql+pymysql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}")

# ---------------------------------------------------------------------
# 2. FILE LOCATIONS — update to wherever you saved the Kaggle CSVs
# ---------------------------------------------------------------------
DATA_DIR = "C:/Users/akshp/Downloads/credit_risk_project/"
# Mac/Linux example: DATA_DIR = "/Users/yourname/Downloads/home-credit/"

FILES = {
    "stg_application": "application_train.csv",
    "stg_bureau": "bureau.csv",
    "stg_previous_application": "previous_application.csv",
    "stg_installments_payments": "installments_payments.csv",
}

# ---------------------------------------------------------------------
# 3. LOAD EACH FILE
# ---------------------------------------------------------------------
for table_name, filename in FILES.items():
    path = DATA_DIR + filename
    print(f"Loading {filename} -> {table_name} ...")

    if filename == "installments_payments.csv":
        # ~13.6M rows — load in chunks so we don't blow up memory
        chunksize = 200_000
        first_chunk = True
        for chunk in pd.read_csv(path, chunksize=chunksize):
            chunk.columns = [c.lower() for c in chunk.columns]
            chunk.to_sql(
                table_name,
                engine,
                if_exists="replace" if first_chunk else "append",
                index=False,
            )
            first_chunk = False
    else:
        df = pd.read_csv(path)
        df.columns = [c.lower() for c in df.columns]  # avoids Postgres case-sensitivity headaches
        df.to_sql(table_name, engine, if_exists="replace", index=False)

    print(f"  done: {table_name}")

print("\nAll files loaded. Open your SQL tool and run sql_walkthrough.sql against the stg_ tables.")
