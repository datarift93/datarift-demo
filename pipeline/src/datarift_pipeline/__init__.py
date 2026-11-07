"""datarift-demo data pipeline.

Flow: generator -> staging -> validation -> model -> import log.
NBP EUR/PLN rates are fetched separately and stored in the database.
"""
