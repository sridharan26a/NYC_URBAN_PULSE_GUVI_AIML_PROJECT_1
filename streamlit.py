import pandas as pd
import plotly.express as px
import streamlit as st
import subprocess, sys

st.set_page_config(page_title="NYC Urban Pulse", layout="wide")

USE_POSTGRES = False      # set True to read the service_request table instead of the CSV
LIMIT_HOURS = 72          # project-defined illustrative threshold, not an official standard
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

# ---------- load the data once per session
if "data" not in st.session_state:
    try:
        if USE_POSTGRES:
            from sqlalchemy import create_engine

            engine = create_engine("postgresql+psycopg2://postgres:sriO0088@localhost:5432/nyc_urban_pulse_db")
            data = pd.read_sql("SELECT * FROM service_request", engine)
        else:
            data = pd.read_csv("nyc311_cleaned.csv")
    except Exception as error:
        st.error("Could not load the data. Check the database connection, or that nyc311_cleaned.csv "
                 "is in the same folder as this file.")
        st.code(str(error))
        st.stop()

    data["created_date"] = pd.to_datetime(data["created_date"])
    data["resolution_action_updated_date"] = pd.to_datetime(data["resolution_action_updated_date"])
    data["created_day"] = data["created_date"].dt.normalize()
    hours = (data["resolution_action_updated_date"] - data["created_date"]).dt.total_seconds() / 3600
    data["valid_hours"] = hours.where(data["is_closed"] & (hours >= 0))   # closed, update not before creation
    st.session_state["data"] = data

data = st.session_state["data"]

# ---------- sidebar: page menu and filters
st.sidebar.title("Urban Pulse")
page = st.sidebar.radio("Page", ["Overview", "Time", "Resolution", "Closure", "Map", "Records"])

first_day = data["created_day"].min().date()
last_day = data["created_day"].max().date()
dates = st.sidebar.date_input("Created between", (first_day, last_day), min_value=first_day, max_value=last_day)
boroughs = st.sidebar.multiselect("Borough", sorted(data["borough"].unique()))
types = st.sidebar.multiselect("Complaint type", sorted(data["complaint_type"].unique()))

df = data
if len(dates) == 2:
    df = df[(df["created_day"] >= pd.Timestamp(dates[0])) & (df["created_day"] <= pd.Timestamp(dates[1]))]
if boroughs:
    df = df[df["borough"].isin(boroughs)]
if types:
    df = df[df["complaint_type"].isin(types)]

st.title("NYC 311 Service Requests")

if df.empty:
    st.warning("No requests match these filters. Widen the dates or clear the borough and complaint type.")
    st.stop()

valid = df.dropna(subset=["valid_hours"])

# ---------- five KPIs
if len(valid) > 0:
    median_text = f"{valid['valid_hours'].median():.1f} h"
    over_text = f"{(valid['valid_hours'] > LIMIT_HOURS).mean() * 100:.1f}%"
else:
    median_text = over_text = "n/a"

k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Total requests", f"{df['unique_key'].nunique():,}")
k2.metric("Recorded closure", f"{df['is_closed'].mean() * 100:.1f}%")
k3.metric("Open requests", f"{(~df['is_closed']).sum():,}")
k4.metric("Median resolution", median_text)
k5.metric(f"Over {LIMIT_HOURS} hours", over_text)
st.caption(f"Closure is the recorded status, not citizen satisfaction. The {LIMIT_HOURS}-hour limit is a "
           "project-defined cut-off, not an official service standard. Resolution figures cover closed "
           "requests only.")

# ---------- pages
if page == "Overview":
    left, right = st.columns(2)
    top = df["complaint_type"].value_counts().head(10).sort_values()
    left.plotly_chart(px.bar(x=top.values, y=top.index, orientation="h", title="Top 10 complaint types",
                             labels={"x": "Requests", "y": ""}))
    agency = df["agency"].value_counts().sort_values()
    right.plotly_chart(px.bar(x=agency.values, y=agency.index, orientation="h", title="Agency workload",
                              labels={"x": "Requests", "y": ""}))
    borough = df["borough"].value_counts()
    left.plotly_chart(px.bar(x=borough.index, y=borough.values, title="Requests by borough",
                             labels={"x": "", "y": "Requests"}))
    status = df["status"].value_counts()
    right.plotly_chart(px.pie(names=status.index, values=status.values, hole=0.4, title="Request status"))

elif page == "Time":
    daily = df.groupby("created_day").size()
    st.plotly_chart(px.line(x=daily.index, y=daily.values, markers=True, title="Requests per day",
                            labels={"x": "", "y": "Requests"}))
    left, right = st.columns(2)
    weekday = df["day_of_week"].value_counts().reindex(DAYS).fillna(0)
    left.plotly_chart(px.bar(x=weekday.index, y=weekday.values, title="Demand by weekday",
                             labels={"x": "", "y": "Requests"}))
    hourly = df["hour"].value_counts().sort_index()
    right.plotly_chart(px.bar(x=hourly.index, y=hourly.values, title="Demand by hour",
                              labels={"x": "Hour of day", "y": "Requests"}))

elif page == "Resolution":
    if valid.empty:
        st.info("No closed requests with a valid resolution time for these filters.")
    else:
        left, right = st.columns(2)
        left.subheader("Resolution time in hours")
        left.dataframe(valid["valid_hours"].describe().round(2))
        cap = valid["valid_hours"].quantile(0.99)
        right.plotly_chart(px.histogram(valid[valid["valid_hours"] <= cap], x="valid_hours", nbins=50,
                                        title="Distribution (up to the 99th percentile)"))
        slow = valid.groupby("complaint_type")["valid_hours"].agg(["count", "median"])
        slow = slow[slow["count"] >= 200].sort_values("median", ascending=False).head(10)
        st.subheader("Slowest complaint types (median hours, at least 200 requests)")
        st.dataframe(slow.round(1))

elif page == "Closure":
    left, right = st.columns(2)
    by_borough = df.groupby("borough")["is_closed"].mean().mul(100).round(1)
    left.plotly_chart(px.bar(x=by_borough.index, y=by_borough.values, title="Closure rate by borough (%)",
                             labels={"x": "", "y": "%"}))
    by_agency = df.groupby("agency")["is_closed"].mean().mul(100).round(1)
    right.plotly_chart(px.bar(x=by_agency.index, y=by_agency.values, title="Closure rate by agency (%)",
                              labels={"x": "", "y": "%"}))

elif page == "Map":
    points = df[["latitude", "longitude"]].rename(columns={"latitude": "lat", "longitude": "lon"})
    st.map(points.sample(min(len(points), 20000), random_state=1))
    st.caption("Up to 20,000 randomly chosen requests.")

else:
    st.write(f"{len(df):,} records match the filters. Showing the first 100.")
    st.dataframe(df.drop(columns=["valid_hours"]).head(100))
st.write("Data source: [NYC Open Data](https://data.cityofnewyork.us/Social-Services/311-Service-Requests-from-2010-to-Present/erm2-nwe9)")
st.write(" This project is for educational purposes only. It is not affiliated with or endorsed by the City of New York.")
st.write("!!Thank you!!")
st.write(" WITH REGARDS, SRIDHARAN A")
