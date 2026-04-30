package org.ldbcouncil.snb.impls.workloads.age;

import com.google.common.collect.ImmutableMap;
import org.ldbcouncil.snb.driver.DbException;
import org.ldbcouncil.snb.driver.control.LoggingService;
import org.ldbcouncil.snb.driver.workloads.interactive.*;
import org.ldbcouncil.snb.impls.workloads.QueryType;
import org.ldbcouncil.snb.impls.workloads.age.operationhandlers.AgeListOperationHandler;
import org.ldbcouncil.snb.impls.workloads.age.operationhandlers.AgeSingletonOperationHandler;
import org.ldbcouncil.snb.impls.workloads.age.operationhandlers.AgeUpdateOperationHandler;
import org.ldbcouncil.snb.impls.workloads.db.BaseDb;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

public class AgeDb extends BaseDb<AgeQueryStore> {

    AgeQueryStore queryStore;

    @Override
    protected void onInit(Map<String, String> properties, LoggingService loggingService) throws DbException {
        String queryDir = properties.get("queryDir");
        String graphName = properties.getOrDefault("age_graph_name", "ldbc_snb");
        queryStore = new AgeQueryStore(queryDir, graphName);
        dcs = new AgeDbConnectionState(properties, queryStore);
    }

    // ── Interactive Complex Queries (IC1–IC12) ──

    public static class InteractiveQuery1 extends AgeListOperationHandler<LdbcQuery1, LdbcQuery1Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery1 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery1);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery1 operation) {
            return state.getQueryStore().getQuery1Map(operation);
        }

        @Override
        public LdbcQuery1Result toResult(ResultSet rs) throws SQLException {
            List<String> emails = AgeConverter.toStringList(rs.getObject("friendEmails"));
            List<String> languages = AgeConverter.toStringList(rs.getObject("friendLanguages"));
            List<LdbcQuery1Result.Organization> universities = AgeConverter.asOrganization(rs.getObject("friendUniversities"));
            List<LdbcQuery1Result.Organization> companies = AgeConverter.asOrganization(rs.getObject("friendCompanies"));

            return new LdbcQuery1Result(
                    AgeConverter.toLong(rs.getObject("friendId")),
                    AgeConverter.toStr(rs.getObject("friendLastName")),
                    AgeConverter.toInt(rs.getObject("distanceFromPerson")),
                    AgeConverter.toLong(rs.getObject("friendBirthday")),
                    AgeConverter.toLong(rs.getObject("friendCreationDate")),
                    AgeConverter.toStr(rs.getObject("friendGender")),
                    AgeConverter.toStr(rs.getObject("friendBrowserUsed")),
                    AgeConverter.toStr(rs.getObject("friendLocationIp")),
                    emails,
                    languages,
                    AgeConverter.toStr(rs.getObject("friendCityName")),
                    universities,
                    companies);
        }
    }

    public static class InteractiveQuery2 extends AgeListOperationHandler<LdbcQuery2, LdbcQuery2Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery2 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery2);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery2 operation) {
            return state.getQueryStore().getQuery2Map(operation);
        }

        @Override
        public LdbcQuery2Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery2Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toLong(rs.getObject("postOrCommentId")),
                    AgeConverter.toStr(rs.getObject("postOrCommentContent")),
                    AgeConverter.toLong(rs.getObject("postOrCommentCreationDate")));
        }
    }

    public static class InteractiveQuery3 extends AgeListOperationHandler<LdbcQuery3, LdbcQuery3Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery3 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery3);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery3 operation) {
            return state.getQueryStore().getQuery3Map(operation);
        }

        @Override
        public LdbcQuery3Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery3Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toInt(rs.getObject("xCount")),
                    AgeConverter.toInt(rs.getObject("yCount")),
                    AgeConverter.toInt(rs.getObject("xyCount")));
        }
    }

    public static class InteractiveQuery4 extends AgeListOperationHandler<LdbcQuery4, LdbcQuery4Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery4 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery4);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery4 operation) {
            return state.getQueryStore().getQuery4Map(operation);
        }

        @Override
        public LdbcQuery4Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery4Result(
                    AgeConverter.toStr(rs.getObject("tagName")),
                    AgeConverter.toInt(rs.getObject("postCount")));
        }
    }

    public static class InteractiveQuery5 extends AgeListOperationHandler<LdbcQuery5, LdbcQuery5Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery5 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery5);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery5 operation) {
            return state.getQueryStore().getQuery5Map(operation);
        }

        @Override
        public LdbcQuery5Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery5Result(
                    AgeConverter.toStr(rs.getObject("forumTitle")),
                    AgeConverter.toInt(rs.getObject("postCount")));
        }
    }

    public static class InteractiveQuery6 extends AgeListOperationHandler<LdbcQuery6, LdbcQuery6Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery6 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery6);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery6 operation) {
            return state.getQueryStore().getQuery6Map(operation);
        }

        @Override
        public LdbcQuery6Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery6Result(
                    AgeConverter.toStr(rs.getObject("tagName")),
                    AgeConverter.toInt(rs.getObject("postCount")));
        }
    }

    public static class InteractiveQuery7 extends AgeListOperationHandler<LdbcQuery7, LdbcQuery7Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery7 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery7);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery7 operation) {
            return state.getQueryStore().getQuery7Map(operation);
        }

        @Override
        public LdbcQuery7Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery7Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toLong(rs.getObject("likeCreationDate")),
                    AgeConverter.toLong(rs.getObject("messageId")),
                    AgeConverter.toStr(rs.getObject("messageContent")),
                    AgeConverter.toInt(rs.getObject("minutesLatency")),
                    AgeConverter.toBool(rs.getObject("isNew")));
        }
    }

    public static class InteractiveQuery8 extends AgeListOperationHandler<LdbcQuery8, LdbcQuery8Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery8 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery8);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery8 operation) {
            return state.getQueryStore().getQuery8Map(operation);
        }

        @Override
        public LdbcQuery8Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery8Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toLong(rs.getObject("commentCreationDate")),
                    AgeConverter.toLong(rs.getObject("commentId")),
                    AgeConverter.toStr(rs.getObject("commentContent")));
        }
    }

    public static class InteractiveQuery9 extends AgeListOperationHandler<LdbcQuery9, LdbcQuery9Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery9 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery9);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery9 operation) {
            return state.getQueryStore().getQuery9Map(operation);
        }

        @Override
        public LdbcQuery9Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery9Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toLong(rs.getObject("messageId")),
                    AgeConverter.toStr(rs.getObject("messageContent")),
                    AgeConverter.toLong(rs.getObject("messageCreationDate")));
        }
    }

    public static class InteractiveQuery10 extends AgeListOperationHandler<LdbcQuery10, LdbcQuery10Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery10 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery10);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery10 operation) {
            return state.getQueryStore().getQuery10Map(operation);
        }

        @Override
        public LdbcQuery10Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery10Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toInt(rs.getObject("commonInterestScore")),
                    AgeConverter.toStr(rs.getObject("personGender")),
                    AgeConverter.toStr(rs.getObject("personCityName")));
        }
    }

    public static class InteractiveQuery11 extends AgeListOperationHandler<LdbcQuery11, LdbcQuery11Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery11 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery11);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery11 operation) {
            return state.getQueryStore().getQuery11Map(operation);
        }

        @Override
        public LdbcQuery11Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery11Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toStr(rs.getObject("organizationName")),
                    AgeConverter.toInt(rs.getObject("organizationWorkFromYear")));
        }
    }

    public static class InteractiveQuery12 extends AgeListOperationHandler<LdbcQuery12, LdbcQuery12Result> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcQuery12 operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveComplexQuery12);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcQuery12 operation) {
            return state.getQueryStore().getQuery12Map(operation);
        }

        @Override
        public LdbcQuery12Result toResult(ResultSet rs) throws SQLException {
            return new LdbcQuery12Result(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("personFirstName")),
                    AgeConverter.toStr(rs.getObject("personLastName")),
                    AgeConverter.toStringList(rs.getObject("tagNames")),
                    AgeConverter.toInt(rs.getObject("replyCount")));
        }
    }

    // IC13 and IC14 are handled by dedicated handler classes (no inner class needed)

    // ── Interactive Short Queries (IS1–IS7) ──

    public static class ShortQuery1PersonProfile extends AgeSingletonOperationHandler<LdbcShortQuery1PersonProfile, LdbcShortQuery1PersonProfileResult> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcShortQuery1PersonProfile operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveShortQuery1);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcShortQuery1PersonProfile operation) {
            return state.getQueryStore().getShortQuery1PersonProfileMap(operation);
        }

        @Override
        public LdbcShortQuery1PersonProfileResult toResult(ResultSet rs) throws SQLException {
            return new LdbcShortQuery1PersonProfileResult(
                    AgeConverter.toStr(rs.getObject("firstName")),
                    AgeConverter.toStr(rs.getObject("lastName")),
                    AgeConverter.toLong(rs.getObject("birthday")),
                    AgeConverter.toStr(rs.getObject("locationIP")),
                    AgeConverter.toStr(rs.getObject("browserUsed")),
                    AgeConverter.toLong(rs.getObject("cityId")),
                    AgeConverter.toStr(rs.getObject("gender")),
                    AgeConverter.toLong(rs.getObject("creationDate")));
        }
    }

    public static class ShortQuery2PersonPosts extends AgeListOperationHandler<LdbcShortQuery2PersonPosts, LdbcShortQuery2PersonPostsResult> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcShortQuery2PersonPosts operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveShortQuery2);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcShortQuery2PersonPosts operation) {
            return state.getQueryStore().getShortQuery2PersonPostsMap(operation);
        }

        @Override
        public LdbcShortQuery2PersonPostsResult toResult(ResultSet rs) throws SQLException {
            return new LdbcShortQuery2PersonPostsResult(
                    AgeConverter.toLong(rs.getObject("messageId")),
                    AgeConverter.toStr(rs.getObject("messageContent")),
                    AgeConverter.toLong(rs.getObject("messageCreationDate")),
                    AgeConverter.toLong(rs.getObject("originalPostId")),
                    AgeConverter.toLong(rs.getObject("originalPostAuthorId")),
                    AgeConverter.toStr(rs.getObject("originalPostAuthorFirstName")),
                    AgeConverter.toStr(rs.getObject("originalPostAuthorLastName")));
        }
    }

    public static class ShortQuery3PersonFriends extends AgeListOperationHandler<LdbcShortQuery3PersonFriends, LdbcShortQuery3PersonFriendsResult> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcShortQuery3PersonFriends operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveShortQuery3);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcShortQuery3PersonFriends operation) {
            return state.getQueryStore().getShortQuery3PersonFriendsMap(operation);
        }

        @Override
        public LdbcShortQuery3PersonFriendsResult toResult(ResultSet rs) throws SQLException {
            return new LdbcShortQuery3PersonFriendsResult(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("firstName")),
                    AgeConverter.toStr(rs.getObject("lastName")),
                    AgeConverter.toLong(rs.getObject("friendshipCreationDate")));
        }
    }

    public static class ShortQuery4MessageContent extends AgeSingletonOperationHandler<LdbcShortQuery4MessageContent, LdbcShortQuery4MessageContentResult> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcShortQuery4MessageContent operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveShortQuery4);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcShortQuery4MessageContent operation) {
            return state.getQueryStore().getShortQuery4MessageContentMap(operation);
        }

        @Override
        public LdbcShortQuery4MessageContentResult toResult(ResultSet rs) throws SQLException {
            return new LdbcShortQuery4MessageContentResult(
                    AgeConverter.toStr(rs.getObject("messageContent")),
                    AgeConverter.toLong(rs.getObject("messageCreationDate")));
        }
    }

    public static class ShortQuery5MessageCreator extends AgeSingletonOperationHandler<LdbcShortQuery5MessageCreator, LdbcShortQuery5MessageCreatorResult> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcShortQuery5MessageCreator operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveShortQuery5);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcShortQuery5MessageCreator operation) {
            return state.getQueryStore().getShortQuery5MessageCreatorMap(operation);
        }

        @Override
        public LdbcShortQuery5MessageCreatorResult toResult(ResultSet rs) throws SQLException {
            return new LdbcShortQuery5MessageCreatorResult(
                    AgeConverter.toLong(rs.getObject("personId")),
                    AgeConverter.toStr(rs.getObject("firstName")),
                    AgeConverter.toStr(rs.getObject("lastName")));
        }
    }

    public static class ShortQuery6MessageForum extends AgeSingletonOperationHandler<LdbcShortQuery6MessageForum, LdbcShortQuery6MessageForumResult> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcShortQuery6MessageForum operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveShortQuery6);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcShortQuery6MessageForum operation) {
            return state.getQueryStore().getShortQuery6MessageForumMap(operation);
        }

        @Override
        public LdbcShortQuery6MessageForumResult toResult(ResultSet rs) throws SQLException {
            return new LdbcShortQuery6MessageForumResult(
                    AgeConverter.toLong(rs.getObject("forumId")),
                    AgeConverter.toStr(rs.getObject("forumTitle")),
                    AgeConverter.toLong(rs.getObject("moderatorId")),
                    AgeConverter.toStr(rs.getObject("moderatorFirstName")),
                    AgeConverter.toStr(rs.getObject("moderatorLastName")));
        }
    }

    public static class ShortQuery7MessageReplies extends AgeListOperationHandler<LdbcShortQuery7MessageReplies, LdbcShortQuery7MessageRepliesResult> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcShortQuery7MessageReplies operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveShortQuery7);
        }

        @Override
        public Map<String, Object> getParameters(AgeDbConnectionState state, LdbcShortQuery7MessageReplies operation) {
            return state.getQueryStore().getShortQuery7MessageRepliesMap(operation);
        }

        @Override
        public LdbcShortQuery7MessageRepliesResult toResult(ResultSet rs) throws SQLException {
            return new LdbcShortQuery7MessageRepliesResult(
                    AgeConverter.toLong(rs.getObject("commentId")),
                    AgeConverter.toStr(rs.getObject("commentContent")),
                    AgeConverter.toLong(rs.getObject("commentCreationDate")),
                    AgeConverter.toLong(rs.getObject("replyAuthorId")),
                    AgeConverter.toStr(rs.getObject("replyAuthorFirstName")),
                    AgeConverter.toStr(rs.getObject("replyAuthorLastName")),
                    AgeConverter.toBool(rs.getObject("replyAuthorKnowsOriginalMessageAuthor")));
        }
    }

    // ── Interactive Update Queries (IU1–IU8) ──

    public static class Update1AddPerson extends AgeUpdateOperationHandler<LdbcUpdate1AddPerson> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate1AddPerson operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate1);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate1AddPerson operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate1AddPerson.PERSON_ID, operation.getPersonId())
                    .put(LdbcUpdate1AddPerson.PERSON_FIRST_NAME, AgeConverter.escapeCypherString(operation.getPersonFirstName()))
                    .put(LdbcUpdate1AddPerson.PERSON_LAST_NAME, AgeConverter.escapeCypherString(operation.getPersonLastName()))
                    .put(LdbcUpdate1AddPerson.GENDER, AgeConverter.escapeCypherString(operation.getGender()))
                    .put(LdbcUpdate1AddPerson.BIRTHDAY, operation.getBirthday().getTime())
                    .put(LdbcUpdate1AddPerson.CREATION_DATE, operation.getCreationDate().getTime())
                    .put(LdbcUpdate1AddPerson.LOCATION_IP, AgeConverter.escapeCypherString(operation.getLocationIp()))
                    .put(LdbcUpdate1AddPerson.BROWSER_USED, AgeConverter.escapeCypherString(operation.getBrowserUsed()))
                    .put(LdbcUpdate1AddPerson.CITY_ID, operation.getCityId())
                    .put(LdbcUpdate1AddPerson.LANGUAGES, AgeConverter.convertTagIds(
                            operation.getLanguages().stream().map(l -> 0L).collect(Collectors.toList())))
                    .put(LdbcUpdate1AddPerson.EMAILS, operation.getEmails().toString())
                    .put(LdbcUpdate1AddPerson.TAG_IDS, AgeConverter.convertTagIds(operation.getTagIds()))
                    .put(LdbcUpdate1AddPerson.STUDY_AT, AgeConverter.convertOrganizations(operation.getStudyAt()))
                    .put(LdbcUpdate1AddPerson.WORK_AT, AgeConverter.convertOrganizations(operation.getWorkAt()))
                    .build();
        }
    }

    public static class Update2AddPostLike extends AgeUpdateOperationHandler<LdbcUpdate2AddPostLike> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate2AddPostLike operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate2);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate2AddPostLike operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate2AddPostLike.PERSON_ID, operation.getPersonId())
                    .put(LdbcUpdate2AddPostLike.POST_ID, operation.getPostId())
                    .put(LdbcUpdate2AddPostLike.CREATION_DATE, operation.getCreationDate().getTime())
                    .build();
        }
    }

    public static class Update3AddCommentLike extends AgeUpdateOperationHandler<LdbcUpdate3AddCommentLike> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate3AddCommentLike operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate3);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate3AddCommentLike operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate3AddCommentLike.PERSON_ID, operation.getPersonId())
                    .put(LdbcUpdate3AddCommentLike.COMMENT_ID, operation.getCommentId())
                    .put(LdbcUpdate3AddCommentLike.CREATION_DATE, operation.getCreationDate().getTime())
                    .build();
        }
    }

    public static class Update4AddForum extends AgeUpdateOperationHandler<LdbcUpdate4AddForum> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate4AddForum operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate4);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate4AddForum operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate4AddForum.FORUM_ID, operation.getForumId())
                    .put(LdbcUpdate4AddForum.FORUM_TITLE, AgeConverter.escapeCypherString(operation.getForumTitle()))
                    .put(LdbcUpdate4AddForum.CREATION_DATE, operation.getCreationDate().getTime())
                    .put(LdbcUpdate4AddForum.MODERATOR_PERSON_ID, operation.getModeratorPersonId())
                    .put(LdbcUpdate4AddForum.TAG_IDS, AgeConverter.convertTagIds(operation.getTagIds()))
                    .build();
        }
    }

    public static class Update5AddForumMembership extends AgeUpdateOperationHandler<LdbcUpdate5AddForumMembership> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate5AddForumMembership operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate5);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate5AddForumMembership operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate5AddForumMembership.FORUM_ID, operation.getForumId())
                    .put(LdbcUpdate5AddForumMembership.PERSON_ID, operation.getPersonId())
                    .put(LdbcUpdate5AddForumMembership.JOIN_DATE, operation.getJoinDate().getTime())
                    .build();
        }
    }

    public static class Update6AddPost extends AgeUpdateOperationHandler<LdbcUpdate6AddPost> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate6AddPost operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate6);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate6AddPost operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate6AddPost.POST_ID, operation.getPostId())
                    .put(LdbcUpdate6AddPost.IMAGE_FILE, AgeConverter.escapeCypherString(operation.getImageFile()))
                    .put(LdbcUpdate6AddPost.CREATION_DATE, operation.getCreationDate().getTime())
                    .put(LdbcUpdate6AddPost.LOCATION_IP, AgeConverter.escapeCypherString(operation.getLocationIp()))
                    .put(LdbcUpdate6AddPost.BROWSER_USED, AgeConverter.escapeCypherString(operation.getBrowserUsed()))
                    .put(LdbcUpdate6AddPost.LANGUAGE, AgeConverter.escapeCypherString(operation.getLanguage()))
                    .put(LdbcUpdate6AddPost.CONTENT, AgeConverter.escapeCypherString(operation.getContent()))
                    .put(LdbcUpdate6AddPost.LENGTH, operation.getLength())
                    .put(LdbcUpdate6AddPost.AUTHOR_PERSON_ID, operation.getAuthorPersonId())
                    .put(LdbcUpdate6AddPost.FORUM_ID, operation.getForumId())
                    .put(LdbcUpdate6AddPost.COUNTRY_ID, operation.getCountryId())
                    .put(LdbcUpdate6AddPost.TAG_IDS, AgeConverter.convertTagIds(operation.getTagIds()))
                    .build();
        }
    }

    public static class Update7AddComment extends AgeUpdateOperationHandler<LdbcUpdate7AddComment> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate7AddComment operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate7);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate7AddComment operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate7AddComment.COMMENT_ID, operation.getCommentId())
                    .put(LdbcUpdate7AddComment.CREATION_DATE, operation.getCreationDate().getTime())
                    .put(LdbcUpdate7AddComment.LOCATION_IP, AgeConverter.escapeCypherString(operation.getLocationIp()))
                    .put(LdbcUpdate7AddComment.BROWSER_USED, AgeConverter.escapeCypherString(operation.getBrowserUsed()))
                    .put(LdbcUpdate7AddComment.CONTENT, AgeConverter.escapeCypherString(operation.getContent()))
                    .put(LdbcUpdate7AddComment.LENGTH, operation.getLength())
                    .put(LdbcUpdate7AddComment.AUTHOR_PERSON_ID, operation.getAuthorPersonId())
                    .put(LdbcUpdate7AddComment.COUNTRY_ID, operation.getCountryId())
                    .put(LdbcUpdate7AddComment.REPLY_TO_POST_ID, operation.getReplyToPostId())
                    .put(LdbcUpdate7AddComment.REPLY_TO_COMMENT_ID, operation.getReplyToCommentId())
                    .put(LdbcUpdate7AddComment.TAG_IDS, AgeConverter.convertTagIds(operation.getTagIds()))
                    .build();
        }
    }

    public static class Update8AddFriendship extends AgeUpdateOperationHandler<LdbcUpdate8AddFriendship> {
        @Override
        public String getQueryString(AgeDbConnectionState state, LdbcUpdate8AddFriendship operation) {
            return state.getQueryStore().getParameterizedQuery(QueryType.InteractiveUpdate8);
        }

        @Override
        public Map<String, Object> getParameters(LdbcUpdate8AddFriendship operation) {
            return ImmutableMap.<String, Object>builder()
                    .put(LdbcUpdate8AddFriendship.PERSON1_ID, operation.getPerson1Id())
                    .put(LdbcUpdate8AddFriendship.PERSON2_ID, operation.getPerson2Id())
                    .put(LdbcUpdate8AddFriendship.CREATION_DATE, operation.getCreationDate().getTime())
                    .build();
        }
    }
}
